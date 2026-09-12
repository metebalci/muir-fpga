// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// THE WHOLE MACHINE ON THE BAND, WITH THE PACK SIDE AS FABRIC AND THE
// WATCHPOINT ON THE 64-BIT BEAT.
//
// **WHY THIS EXISTS.**  `make hash-watch` cleared `rtl/machine/` of CLAUDE.md's
// page-hash-table defect over 171,000,000 microcycles, and `make band-axi`
// cleared `cadr_axi_master` and `cadr_axi_widen` over 13,000,000 onto a real
// 64-bit AXI3 port.  Both of those harnesses PLAY the pack side: they bring
// the block store's seam out and a testbench writes 259 words into a slot.
// `rtl/plumbing/cadr_disk_pack.sv` has never been INSTANTIATED in a
// whole-machine check --- `disk_pack.pass` holds it to properties on a
// directed stimulus with no machine behind it --- and `S_AXI_HP2` and the
// `cadr-disk-packs` program are outside all of it.  That is the last seam in
// this tree that a simulation can reach, and this is it reached.
//
// This file is `tb/cadr_band_axi_tb.cpp` with ONE THING CHANGED: where the
// pack comes from.  The DUT is `tb/cadr_pack_axi_harness.sv`, which is the
// band harness with `cadr_disk_pack` between the machine and the testbench as
// `boards/arty-z7-20/cadr_arty.sv` puts it; the feeder on the seam is replaced
// by `tb/cadr_pack_linux.h`'s Linux --- GP0 register accesses and an AXI3
// slave on HP2 --- and every other line, the trace comparison, the watchpoint,
// the three instruments, the screen counter and the readout, is that file's.
// The two runs are therefore comparable and a difference between them is
// about the pack side and nothing else.
//
// **THE TWO PORTS SHARE ONE MEMORY, AND THAT IS AN INSTRUMENT.**  On the board
// `S_AXI_HP0` and `S_AXI_HP2` are two doors into one DRAM.  Here they are two
// faces onto the same array, so a pack-side master that wandered into the
// machine's own region lands in `main_mem` where the watchpoint and the
// untouched-word accounting can see it.  Two arrays would make that fault
// unreachable by construction, which is the mistake this project keeps
// meeting: a check written so that the thing it is for cannot happen.
//
// **THE STAGING RECORDS ARE `pack_feeder.h`'s OWN ADDRESSES**, 0x1C80_0000 and
// up, which is the spare part of the CADR's 128 MB reservation past main
// memory's 64 MB and the display's 8 MB.  A record placed there and a record
// placed anywhere else are different experiments, and this one is the board's.
//

// Flags are `tb/cadr_hash_watch_tb.cpp`'s, unchanged.
#include <cstdarg>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

#include "Vcadr_pack_axi_harness.h"
#include "cadr_pack_linux.h"
#include "verilated.h"

namespace {

// The fabric's tick, as every testbench here counts it, and the bus's own
// read deskew.  `cadr_phase_gen.sv`'s TICK_NS: a number of MIT's nanoseconds
// a tick stands for, which is what every constant in the machine is written
// in.  It is not the board's clock period and does not move with it.
constexpr long kTickNs = 5;
constexpr int kXbusAckNs = 60;

// ------------------------------------------------------------ the trace

// The trace's columns, in the order golden/src/trace.rs prints them.
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

// ------------------------------------------------------------ the pack

// `disk_unit::Geometry::T300`, which is what `golden/src/rtl_sys.rs` attaches.
constexpr uint32_t kCylinders = 815;
constexpr uint32_t kHeads = 19;
constexpr uint32_t kBlocksPerTrack = 17;
constexpr int kBlockWords = 256;

// `Ecc`, the controller's error-correcting register as DCECC wires it: thirty
// -two stages, taps 31, 29, 20, 10 and 8, a bit at a time low-order first.
// With feedback off a shift is a shift, so `Ecc::checkword()` read back as a
// little-endian word IS `Ecc::raw()`, and the table below is that register
// stepped eight bits at a time.  `tb/cadr_pack_side.h` writes the same code a
// bit at a time; this one runs over a kilobyte a block, tens of thousands of
// times.
constexpr uint32_t kEccPoly = 0xA0100500u;

struct Ecc {
  static const uint32_t *table() {
    static uint32_t t[256];
    static bool built = false;
    if (!built) {
      for (int i = 0; i < 256; ++i) {
        uint32_t r = static_cast<uint32_t>(i);
        for (int k = 0; k < 8; ++k) r = (r & 1u) ? (r >> 1) ^ kEccPoly : (r >> 1);
        t[i] = r;
      }
      built = true;
    }
    return t;
  }
  static uint32_t over_bytes(const uint8_t *b, size_t n) {
    const uint32_t *t = table();
    uint32_t r = 0;
    for (size_t i = 0; i < n; ++i) r = (r >> 8) ^ t[(r ^ b[i]) & 0xFFu];
    return r;
  }
  static uint32_t over_words(const uint32_t *w, int n) {
    const uint32_t *t = table();
    uint32_t r = 0;
    for (int i = 0; i < n; ++i)
      for (int k = 0; k < 4; ++k)
        r = (r >> 8) ^ t[(r ^ (w[i] >> (8 * k))) & 0xFFu];
    return r;
  }
};

// `disk_unit::header_of`: the next-block code above the address itself.
uint32_t HeaderOf(uint32_t c, uint32_t h, uint32_t b) {
  uint32_t code;
  if (b + 1 < kBlocksPerTrack) code = 0;
  else if (h + 1 < kHeads) code = 1;
  else if (c + 1 < kCylinders) code = 2;
  else code = 3;
  return code << 30 | (c & 0xFFFu) << 16 | (h & 0xFFu) << 8 | (b & 0xFFu);
}

// The pack: the release image, read-only, with what the machine has written
// kept in memory for the run.  muir's `Unit` with `open_rw` writes the file;
// the starting state is the same either way and this never touches the image,
// so the copy stays exactly the bytes the reference was taken against.
class Pack {
 public:
  bool Open(const char *path) {
    f_ = std::fopen(path, "rb");
    if (!f_) return false;
    std::fseek(f_, 0, SEEK_END);
    const long got = std::ftell(f_);
    const long want =
        static_cast<long>(kCylinders) * kHeads * kBlocksPerTrack * kBlockWords * 4;
    if (got != want) {
      std::fprintf(stderr, "%s: %ld bytes, expected %ld\n", path, got, want);
      return false;
    }
    return true;
  }
  bool OnPack(uint32_t c, uint32_t h, uint32_t b) const {
    return c < kCylinders && h < kHeads && b < kBlocksPerTrack;
  }
  uint32_t Lba(uint32_t c, uint32_t h, uint32_t b) const {
    return c * (kHeads * kBlocksPerTrack) + h * kBlocksPerTrack + b;
  }
  // The block as the drive would read it: what the machine last wrote, else
  // what the image holds.
  bool Read(uint32_t c, uint32_t h, uint32_t b, uint32_t *out) {
    if (!OnPack(c, h, b)) return false;
    const uint32_t lba = Lba(c, h, b);
    auto it = written_.find(lba);
    if (it != written_.end()) {
      std::memcpy(out, it->second.data(), kBlockWords * 4);
      ++served_written_;
      return true;
    }
    uint8_t bytes[kBlockWords * 4];
    if (std::fseek(f_, static_cast<long>(lba) * sizeof bytes, SEEK_SET) != 0) return false;
    if (std::fread(bytes, 1, sizeof bytes, f_) != sizeof bytes) return false;
    // The image holds each 32-bit word low byte first.
    for (int i = 0; i < kBlockWords; ++i)
      out[i] = static_cast<uint32_t>(bytes[4 * i]) |
               static_cast<uint32_t>(bytes[4 * i + 1]) << 8 |
               static_cast<uint32_t>(bytes[4 * i + 2]) << 16 |
               static_cast<uint32_t>(bytes[4 * i + 3]) << 24;
    ++served_image_;
    return true;
  }
  void Write(uint32_t c, uint32_t h, uint32_t b, const uint32_t *in) {
    if (!OnPack(c, h, b)) return;
    auto &slot = written_[Lba(c, h, b)];
    slot.assign(in, in + kBlockWords);
    ++written_blocks_;
  }
  long served_image() const { return served_image_; }
  long served_written() const { return served_written_; }
  long written_blocks() const { return written_blocks_; }
  size_t distinct_written() const { return written_.size(); }

 private:
  std::FILE *f_ = nullptr;
  std::map<uint32_t, std::vector<uint32_t>> written_;
  long served_image_ = 0, served_written_ = 0, written_blocks_ = 0;
};

// ------------------------------------------------------------ reporting

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
}

// A word that is not zero, not any other word's, and not the address.
uint32_t Poison(uint32_t byte_addr) {
  const uint32_t w = byte_addr >> 2;
  uint32_t p = (0x9E3779B9u * (w + 1u)) ^ 0xA5A5A5A5u;
  if (p == 0) p = 0xFEEDFACEu;
  return p;
}

// ------------------------------------------------------------ the sample

// Every column this check compares, taken before the microcycle's own edge.
// It is also the key `--absorb` matches a wait loop on, which is why it is one
// struct and not a list of reads: a partial key would let two different states
// of the machine look like one going round again.
struct Sample {
  uint64_t ir;
  uint32_t st, a, m, alu, r, ob, q, vma, md;
  uint32_t lc;
  uint16_t pc, lpc, opc, dc;
  uint8_t vmaok, jcond, nop, pcs1, pcs0, iwrited, promdis, sintr;

  bool operator==(const Sample &o) const {
    return std::memcmp(this, &o, sizeof *this) == 0;
  }
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *trace_path = nullptr;
  const char *pack_path = nullptr;
  // The most microcycles the fabric may run past a reference row before
  // arriving at it.  Zero --- the default --- is a strict comparison with no
  // edit of any kind.
  long absorb_cap = 0;
  uint64_t stop_at = 0;
  // **AN INSTRUMENT AND NOT A CHECK.**  Past the first disagreement the
  // comparison is over; what `--observe` does is go on clocking the fabric
  // and report what it does on its own --- when it leaves the boot PROM, how
  // many blocks it moves, and what each transfer costs it in microcycles ---
  // which is the measurement that says what the fabric and muir cannot be
  // compared across.  It asserts nothing.
  uint64_t observe = 0;
  int timed = 0;
  long tolerate = 0;
  // THE FLOOR, AND WHY IT IS A `>=` AND NOT AN `==`.  Measured at `822535c`:
  // the whole machine agrees with muir for this many microcycles of the band
  // with a real memory and a real pack under it, and stops at the machine's
  // first disk transfer for the reason the header gives.  A change that makes
  // the two agree for FEWER is a regression and fails here; a change that
  // makes them agree for more --- a reference generated with the drive's time
  // charged would --- passes and prints the new figure, and whoever makes it
  // raises this.
  uint64_t floor = 1062507;

  // ============================= THE WATCHPOINT ==============================
  //
  // CLAUDE.md's "THE BOARD PUT A STALE MEMORY DATA WORD INTO THE PAGE HASH
  // TABLE" says the corruption is a WRITE that should not have happened, and
  // that `cadr_memory_path.sv` loads `wdata <= md` at MEMGO REGARDLESS OF
  // DIRECTION --- so on every read the whole of MD stands on `mem_wdata` at
  // the bridge and one wrong bit of `mem_write` replaces the word being read.
  // Three instruments, all of them free:
  //
  //   1. `--watch <octal physical word>`, repeatable: every transaction that
  //      touches the word, with the microcycle, the direction, the data, the
  //      processor's own WRCYC and whether the channel owned the bus.
  //   2. ONE TRANSACTION PER BUS CYCLE, over the whole run.  CLAUDE.md:
  //      "nothing in the tree counts transactions per bus cycle ... That is
  //      the next check to build, and it is the one this bug has been living
  //      behind."  `mem_req` stands until the bridge has taken the word, so
  //      re-serving inside one `mem_req` is a duplicated transaction.
  //   3. A WRITE NOBODY ASKED FOR: `mem_write` up while the processor's own
  //      `dev_write` (which is `cpu_write`, off the WRCYC flip flop) is down
  //      and the channel is not running.  That is the defect written as an
  //      invariant rather than as an address.
  std::vector<uint32_t> watch_words;      // CADR physical WORD addresses
  uint64_t halt_quiet = 100000;           // ticks with no microcycle = stopped
  uint64_t mem_delay = 0;                 // ticks the memory takes past the trace
  uint64_t progress = 0;                  // say where the machine is, this often
  // WHAT AN UNWRITTEN WORD OF DDR READS AS.  CLAUDE.md, measured on the board
  // before anything was written: "Uninitialised DDR reads as alternating bands
  // of zeros and ones, not as zero ... So an unwritten word reads 0x00000000
  // in some places and 0xFFFFFFFF in others, and anything taking either as
  // evidence a write happened is testing nothing."  muir's memory is zero and
  // so is this model's, so the two machines differ wherever the CADR reads a
  // word nothing has written --- which is a difference the board has and no
  // check in this repository has ever had.  Applied PAST THE COMPARISON only,
  // so the 1,062,507 microcycles against muir still mean what they meant.
  uint32_t unwritten = 0u;
  bool free_run = false;                  // no trace at all, straight from reset

  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--watch") && i + 1 < argc) {
      watch_words.push_back(
          static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 8)));
      continue;
    }
    if (!std::strcmp(argv[i], "--halt-quiet") && i + 1 < argc) {
      halt_quiet = std::strtoull(argv[++i], nullptr, 0);
      continue;
    }
    if (!std::strcmp(argv[i], "--free")) { free_run = true; continue; }
    if (!std::strcmp(argv[i], "--unwritten") && i + 1 < argc) {
      unwritten = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 0));
      continue;
    }
    if (!std::strcmp(argv[i], "--progress") && i + 1 < argc) {
      progress = std::strtoull(argv[++i], nullptr, 0);
      continue;
    }
    // WHAT THE MEMORY COSTS PAST THE COMPARISON.  Inside the comparison the
    // answer is placed where muir placed it, out of the trace's `ack` column.
    // Past it there is no column, and the default is to answer as soon as
    // asked --- which is NOT the board, where the word crosses
    // `cadr_axi_master`, `cadr_axi_widen`, a PS7 and a DDR3 controller.
    // CLAUDE.md's own note that "a DDR round trip takes FEWER ticks at a
    // longer tick and the acknowledgement lands on a different tick entirely"
    // says the instant matters, so the delay is a knob and a run says which
    // one it used.  muir's own `Responder::Memory` answers 573 to 608 ns
    // after the grant, which is about 115 of these ticks.
    if (!std::strcmp(argv[i], "--mem-delay") && i + 1 < argc) {
      mem_delay = std::strtoull(argv[++i], nullptr, 0);
      continue;
    }
    if (!std::strcmp(argv[i], "--pack") && i + 1 < argc) pack_path = argv[++i];
    else if (!std::strcmp(argv[i], "--absorb") && i + 1 < argc)
      absorb_cap = std::atol(argv[++i]);
    else if (!std::strcmp(argv[i], "--stop-at") && i + 1 < argc)
      stop_at = std::strtoull(argv[++i], nullptr, 0);
    else if (!std::strcmp(argv[i], "--observe") && i + 1 < argc)
      observe = std::strtoull(argv[++i], nullptr, 0);
    // `Controller::timed`, which must be the same on both sides: the
    // reference has to have been generated with `m.disk.timed = true` for
    // this to mean anything, and the header above says why it is the one
    // thing that makes the two channels finish at the same instant.
    else if (!std::strcmp(argv[i], "--timed")) timed = 1;
    // The most microcycles a disagreement may last before the two machines
    // are back in step.  See `tolerate` at the burst below for what it is for
    // and what it may not be used to hide.
    else if (!std::strcmp(argv[i], "--tolerate") && i + 1 < argc)
      tolerate = std::atol(argv[++i]);
    else if (!std::strcmp(argv[i], "--floor") && i + 1 < argc)
      floor = std::strtoull(argv[++i], nullptr, 0);
    else if (argv[i][0] != '-' && !trace_path) trace_path = argv[i];
  }
  if (!trace_path) trace_path = "build/rtl_sys.golden";

  std::FILE *f = std::fopen(trace_path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", trace_path, std::strerror(errno));
    return 2;
  }

  // The trace is streamed and never held: 392 MB for 2,800,000 microcycles.
  // The row count comes out of the generator's own header line rather than out
  // of a first pass over the file.
  uint64_t total_rows = 0;
  bool skipped = false;
  {
    char line[512];
    long at = 0;
    while (std::fgets(line, sizeof line, f)) {
      if (line[0] != '#') break;
      if (!std::strncmp(line, "# skipped", 9)) { skipped = true; break; }
      unsigned long long n = 0, from = 0;
      if (std::sscanf(line, "# %llu microcycles from %llu", &n, &from) == 2) {
        total_rows = n;
        Check(from == 0,
              "the reference starts at microcycle %llu; a fabric that boots "
              "from reset cannot be put there", from);
      }
      at = std::ftell(f);
    }
    if (skipped) {
      std::printf("band-axi: skipped --- no System 100 release\n");
      std::fclose(f);
      return 0;
    }
    std::fseek(f, at, SEEK_SET);
  }
  if (total_rows == 0) {
    std::fprintf(stderr, "FAIL: %s: no row count in the header\n", trace_path);
    return 1;
  }
  if (stop_at && stop_at < total_rows) total_rows = stop_at;

  // WHEN muir's OWN BUS INTERFACE ANSWERED EACH CYCLE.  One pass over the
  // trace for the `ack` column, which is the only thing that has to be known
  // before its row; everything else is streamed.  A cycle whose answer is not
  // known at the boundary it started on had to arbitrate for the Unibus
  // first, and those are counted rather than exempted.
  std::vector<uint64_t> ack_for(total_rows, 0);
  {
    std::vector<uint64_t> acks(total_rows, 0);
    std::vector<uint64_t> bus_at;
    const long at = std::ftell(f);
    char line[512];
    uint64_t n = 0;
    while (n < total_rows && std::fgets(line, sizeof line, f)) {
      if (line[0] == '#' || line[0] == '\n') continue;
      Row r;
      if (!ParseRow(line, r)) {
        std::fprintf(stderr, "%s: row %" PRIu64 " has the wrong column count\n",
                     trace_path, n);
        return 2;
      }
      acks[n] = r.v[kAck];
      if (r.v[kBus]) bus_at.push_back(n);
      ++n;
    }
    if (n < total_rows) {
      std::fprintf(stderr, "%s: %" PRIu64 " rows, the header says %" PRIu64 "\n",
                   trace_path, n, total_rows);
      return 2;
    }
    for (uint64_t i : bus_at) {
      uint64_t j = i;
      while (j < total_rows && acks[j] == 0) ++j;
      ack_for[i] = (j < total_rows) ? acks[j] : 0;
    }
    std::fseek(f, at, SEEK_SET);
  }

  if (!pack_path) {
    std::fprintf(stderr, "FAIL: --pack <image> is required\n");
    return 2;
  }
  Pack pack;
  if (!pack.Open(pack_path)) {
    std::fprintf(stderr, "FAIL: cannot open the pack %s\n", pack_path);
    return 2;
  }

  // ---------------------------------------------------------- the memory
  //
  // `cadr_ddr_map::MAIN_BASE`, and 16 M words of it, which covers every
  // address 32 memory boards can make.  Zero, as `Machine::with_memory_boards`
  // leaves it; `touched` is what says which words the machine itself put
  // there, so that reads of words nothing wrote are counted rather than
  // believed.
  constexpr uint32_t kMainBase = 0x18000000u;
  constexpr size_t kMainWords = 16u << 20;
  std::vector<uint32_t> main_mem(kMainWords, 0u);
  std::vector<uint8_t> touched(kMainWords, 0u);
  std::unordered_map<uint32_t, uint32_t> elsewhere;   // the display's region

  long mem_reads = 0, mem_writes = 0, mem_untouched_reads = 0;
  long mem_outside = 0, mem_misaligned = 0;

  auto *dut = new Vcadr_pack_axi_harness;
  dut->clk = 0;
  dut->rst = 1;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  // One drive on the cable, writable, and its own time NOT charged:
  // `Controller::timed` is false in muir and `golden/src/rtl_sys.rs` never
  // sets it.
  dut->drive_present = 0x01;
  dut->drive_read_only = 0x00;
  dut->drive_timed = timed;
  // THE SEAM IS NOT DRIVEN HERE, AND SAYING SO IS THE POINT.  In
  // `tb/cadr_band_axi_tb.cpp` these eight were the testbench's own stimulus;
  // `cadr_disk_pack` drives them now and they are outputs of the harness.
  // CLAUDE.md's `md` trap is that Verilator lets you write an output and the
  // write survives wherever the design does not assign it --- here the pack
  // side assigns all eight every tick, so a line left behind would be
  // overwritten rather than silently believed.  They are gone all the same.
  dut->con_ro_addr = 0;
  // The slave at rest.  `hp0_aresetn` is deliberately NOT a port here: a
  // dead port is `tb/cadr_mem_count_harness.sv`'s question and issues no
  // transaction at all, which is the one configuration this has nothing
  // to say about.
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

  // ------------------------------------------------------- the pack side
  //
  // LINUX, AND THE DDR BEHIND HP2.  `tb/cadr_pack_linux.h` is the two AXI
  // faces and the program: an AXI3 slave that counts what the pack side does
  // to it, a single-beat GP0 master, and `cadr-disk-packs`'s own loop as a
  // state machine over register accesses --- take every slot away, put the
  // drive on the cable, then poll REQ and serve what the walk asks for,
  // writing a dirty slot back to the pack before taking it.
  constexpr int kSlots = pack_linux::kSlots;

  pack_linux::Hp2Slave<Vcadr_pack_axi_harness> hp2;
  pack_linux::Gp0Linux<Vcadr_pack_axi_harness> gp0;
  pack_linux::Feeder<Vcadr_pack_axi_harness> feeder;

  long seam_complaints = 0;
  auto seam_fail = [&](const char *what) {
    if (seam_complaints++ < 40) {
      std::printf("PACK SEAM: %s\n", what);
      std::fflush(stdout);
    }
  };
  hp2.complain = seam_fail;
  gp0.complain = seam_fail;

  // THE PACK SIDE'S BEATS LAND IN THE SAME ARRAY THE MACHINE'S DO, and a beat
  // of either master inside the machine's own address range is counted.  The
  // records are at 0x1C80_0000 and up, so a correct run puts NONE there; a
  // pack side that computed an address wrongly would put a whole block there
  // and the watchpoint would see it.
  long hp2_in_main = 0, hp2_outside_staging = 0;
  constexpr uint32_t kStagingTop =
      pack_linux::kSpareBase + 0x20000u;   // FEEDER_MAP_BYTES
  // THE STAGING RECORDS GET THEIR OWN MAP, and not `elsewhere`, which is the
  // DISPLAY'S WINDOW: the run counts the lit words of that map as the picture,
  // and that count is how it says whether the fabric is following muir's
  // program or the board's.  259 words of a disk block in it would read as
  // pixels.
  std::unordered_map<uint32_t, uint32_t> staging;
  auto staged = [&](uint32_t at) -> uint32_t {
    auto it = staging.find(at);
    return (it != staging.end()) ? it->second : Poison(at >> 2);
  };
  auto hp2_read = [&](uint32_t a2) -> uint64_t {
    if (a2 >= kMainBase && a2 + 7u < kMainBase + 4ull * kMainWords) ++hp2_in_main;
    if (a2 < pack_linux::kSpareBase || a2 >= kStagingTop) ++hp2_outside_staging;
    if (a2 >= kMainBase && a2 + 7u < kMainBase + 4ull * kMainWords) {
      const size_t w = (a2 - kMainBase) >> 2;
      return (static_cast<uint64_t>(main_mem[w + 1]) << 32) | main_mem[w];
    }
    return (static_cast<uint64_t>(staged(a2 + 4u)) << 32) | staged(a2);
  };
  auto hp2_write = [&](uint32_t a2, uint64_t v, unsigned strb) {
    if (a2 >= kMainBase && a2 + 7u < kMainBase + 4ull * kMainWords) ++hp2_in_main;
    if (a2 < pack_linux::kSpareBase || a2 >= kStagingTop) ++hp2_outside_staging;
    for (int half = 0; half < 2; ++half) {
      const unsigned m = (strb >> (4 * half)) & 0xFu;
      if (!m) continue;
      const uint32_t at = a2 + 4u * half;
      const bool main = at >= kMainBase && at < kMainBase + 4ull * kMainWords;
      const uint32_t was = main ? main_mem[(at - kMainBase) >> 2] : staged(at);
      uint32_t now = static_cast<uint32_t>(v >> (32 * half));
      for (int by = 0; by < 4; ++by)
        if (!((m >> by) & 1u))
          now = (now & ~(0xFFu << (8 * by))) | (was & (0xFFu << (8 * by)));
      if (main) {
        const size_t w = (at - kMainBase) >> 2;
        main_mem[w] = now;
        touched[w] = 1;
      } else {
        staging[at] = now;
      }
    }
  };
  hp2.rd = hp2_read;
  hp2.wr = hp2_write;

  auto tag_of = [](unsigned unit, unsigned c, unsigned h, unsigned b) {
    return (unit & 7u) << 28 | (c & 0xFFFu) << 16 | (h & 0xFFu) << 8 | (b & 0xFFu);
  };

  feeder.gp0 = &gp0;
  feeder.present = 0x01;
  feeder.read_only = 0x00;
  feeder.timed = timed;
  feeder.read_block = [&](unsigned unit, unsigned c, unsigned h, unsigned b,
                          uint32_t *out) {
    if (unit != 0 || !pack.OnPack(c, h, b)) return false;
    pack.Read(c, h, b, out);
    return true;
  };
  feeder.write_block = [&](unsigned, unsigned c, unsigned h, unsigned b,
                           const uint32_t *w) { pack.Write(c, h, b, w); };
  feeder.header_of = [](unsigned c, unsigned h, unsigned b) {
    return HeaderOf(c, h, b);
  };
  feeder.ecc_bytes = [](const uint8_t *p, int n) { return Ecc::over_bytes(p, n); };
  feeder.ecc_words = [](const uint32_t *p, int n) { return Ecc::over_words(p, n); };
  feeder.poke = [&](uint32_t at, uint32_t w) {
    if (at >= kMainBase && at < kMainBase + 4ull * kMainWords) {
      const size_t wd = (at - kMainBase) >> 2;
      main_mem[wd] = w;
      touched[wd] = 1;
    } else {
      staging[at] = w;
    }
  };
  feeder.peek = [&](uint32_t at) -> uint32_t {
    if (at >= kMainBase && at < kMainBase + 4ull * kMainWords)
      return main_mem[(at - kMainBase) >> 2];
    return staged(at);
  };

  hp2.reset(dut);
  gp0.reset(dut);
  dut->eval();


  // ------------------------------------------------------ the comparison
  auto take = [&]() {
    Sample s;
    std::memset(&s, 0, sizeof s);
    s.ir = dut->ir;
    s.st = dut->st; s.a = dut->a; s.m = dut->m; s.alu = dut->alu;
    s.r = dut->r_bus; s.ob = dut->ob; s.q = dut->q;
    s.vma = dut->vma; s.md = dut->md; s.lc = dut->lc;
    s.pc = dut->pc; s.lpc = dut->lpc; s.opc = dut->opc; s.dc = dut->dc;
    s.vmaok = dut->vmaok; s.jcond = dut->jcond; s.nop = dut->nop;
    s.pcs1 = dut->pcs1; s.pcs0 = dut->pcs0; s.iwrited = dut->iwrited;
    s.promdis = dut->promdisable; s.sintr = dut->sintr_o;
    return s;
  };

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
    std::fprintf(stderr, "FAIL: %s: cannot read the first microcycle\n", trace_path);
    return 1;
  }
  Sample prev = take();

  uint64_t k = 0;                 // the reference row the fabric is on
  uint64_t fabric_cycles = 0;     // microcycles the fabric has run
  int bad = 0;
  bool catching_up = false;
  long near_misses = 0;
  bool in_burst = false;
  long bursts = 0, tolerated = 0, burst_len = 0, burst_longest = 0;
  uint64_t burst_at = 0;
  uint32_t burst_mask = 0;
  int burst_cols = 0;
  std::map<uint32_t, long> burst_masks;
  std::map<int, long> burst_where;
  long absorbed = 0, absorb_runs = 0, absorb_longest = 0, absorb_run = 0;
  std::map<unsigned, long> absorb_pc;
  uint64_t first_absorb = 0;

  // ---- the 64-bit AXI3 slave's own state ---------------------------------
  //
  // One transaction is in flight at a time, which is `cadr_axi_master`'s own
  // rule and not an assumption made here: its header says single beat, one in
  // flight.  The clauses below hold it to that rather than relying on it.
  bool aw_taken = false, w_taken = false, ar_taken = false, committed = false;
  uint32_t aw_addr = 0, ar_addr = 0, w_strb = 0;
  uint64_t w_data = 0;
  uint32_t req_wdata_at_aw = 0;
  // The request window at the bridge's own port, which is what a transaction
  // has to belong to.
  bool in_request = false, req_last_seen = false;
  int req_write = 0;
  uint32_t req_addr = 0;
  long req_aw = 0, req_ar = 0, req_done = 0;
  uint64_t req_tick = 0;
  // The clauses, each counted so that a zero can be read.
  long req_rises = 0, req_read_rises = 0, req_write_rises = 0;
  long aw_handshakes = 0, ar_handshakes = 0, w_handshakes = 0;
  long b_handshakes = 0, r_handshakes = 0;
  long answers_per_request_wrong = 0, txns_per_request_wrong = 0;
  long txns_outside_a_request = 0, direction_wrong = 0;
  long direction_attributable = 0, direction_skipped = 0;
  long beat_unaligned = 0, bad_strobes = 0, strobe_half_wrong = 0;
  long wdata_not_offered_twice = 0, read_lane_wrong = 0;
  long neighbour_disturbed = 0, outside_the_store = 0;
  long clause_shown = 0;
  // What the machine took back, compared against what the store holds at the
  // word the bridge asked for --- the read path's whole contract in one line.
  long words_read_back = 0;
  // The processor's cycle in flight and when muir's own interface answered it.
  bool bus_outstanding = false;
  int64_t ack_at_tick = 0;
  long mem_unkeyed = 0;     // cycles muir has no column for: the channel's
  // When `mem_req` last rose, so a delay past the trace can be measured.
  uint64_t req_rose_at = 0;
  bool req_was = false;

  // ---- the watchpoint's own state ----------------------------------------
  // A word is watched by its CADR physical word address; `mem_addr` is a byte
  // address in the reserved region, so the two differ by the base and a shift.
  std::vector<uint8_t> watched(kMainWords, 0u);
  for (uint32_t wd : watch_words)
    if (wd < kMainWords) watched[wd] = 1;
  long watch_hits = 0;
  long watch_reads = 0, watch_writes = 0;
  // One transaction per `mem_req`, and a write nobody asked for.
  long cycles_counted = 0, cycles_multi = 0, multi_worst = 0;
  long writes_unasked = 0, writes_unasked_shown = 0;
  long multi_shown = 0;
  // The halt, and the fingerprint at it.
  uint64_t quiet_since = 0;
  bool halted = false;
  uint64_t halt_cycle = 0;
  long fingerprint_hits = 0;
  // DOES THE MODEL EXERCISE THE SUSPECT PATH AT ALL?  CLAUDE.md names three
  // places: `PGF-RL` at 0o24074, whose `((MD) A-PGF-VMA)` puts the faulting
  // VMA in MD and whose `((VMA-START-READ) ADD VMA (A-CONSTANT 1))` two
  // instructions later runs a bus cycle at the page hash table's second word
  // carrying that VMA on the write-data lines; `PGF-RWF` at 0o24047, which
  // reads that word and deposits 4 into its status field; and `PGF-W-1` at
  // 0o23551, where the board halts.  A run that never reaches them has not
  // tested the thing, however long it is.
  long visits_pgf_rl = 0, visits_pgf_rl_read = 0, visits_pgf_rwf = 0,
       visits_pgf_w1 = 0;

  // ------------------------------------------------------------- the clock
  //
  // **THE TWO CLOCKS, WHICH NOTHING HAS EVER COMPARED IN ABSOLUTE TERMS.**
  // `machine.pass` and `microcycle.pass` both re-anchor to the trace's own
  // `ns` at every row and exempt a sub-tick slip on stalled rows, so the slip
  // has never been allowed to accumulate in a comparison.  Nothing needed it
  // to: no reference program read anything that was a function of elapsed
  // time.  A drive on the cable does --- its block counter is the spindle's
  // position, `now mod REVOLUTION_NS` --- and so does the I/O board's
  // microsecond counter.  So this measures the drift, says which microcycles
  // it is incurred on, and prints it whether the run agrees or not.
  uint64_t last_edge_tick = 0;
  uint64_t last_muir_ns = 0;
  bool clock_started = false;
  int64_t drift_stalled = 0, drift_plain = 0;
  long rows_stalled = 0, rows_plain = 0;
  std::vector<std::pair<uint64_t, int64_t>> drift_marks;

  // What the fabric does on its own, past the point of comparison.
  uint64_t fabric_promdis_at = 0;
  long transfers = 0;
  uint64_t ch_up_at = 0;
  uint64_t ch_up_cycle = 0;
  bool ch_was = false;
  long ch_ticks_total = 0, ch_cycles_total = 0, ch_longest = 0;
  bool observing = false;

  // The band is 2,800,000 microcycles of about 29 ticks, and the fabric runs
  // more of them than muir does; 256 ticks a reference row is generous and
  // bounded, and the run says so rather than stopping silently.
  const uint64_t max_ticks = (total_rows + observe) * 320ull + 1'000'000ull;
  uint64_t t = 0;
  const char *stopped_because = nullptr;
  uint64_t observe_until = 0;

  for (; t < max_ticks && (observing ? fabric_cycles < observe_until
                                     : k < total_rows); ++t) {
    if (t == 4) dut->rst = 0;

    // ---- the 64-bit AXI3 slave, driving its side of this tick ----------
    //
    // `S_AXI_HP0`'s far end.  Where `tb/cadr_hash_watch_tb.cpp` put a word
    // store on `mem_done`/`mem_rdata`, everything from `cadr_axi_master`
    // outwards is now inside the DUT and this is what answers it.
    //
    // **THE RELEASE IS THE WORD STORE'S OWN GATE, ONE TICK EARLY.**  There
    // the answer was combinational at the tick muir's own interface answered;
    // here `mem_done` is `state == DONE`, which the adapter reaches at the
    // edge AFTER it sees R or B.  So the response is released when the gate
    // would be open at `t + 1`, and `mem_done` lands on the same tick it
    // landed on before --- which is what keeps the band comparison and the
    // two-clock assertion meaning what they meant.
    if (dut->mem_req && !req_was) req_rose_at = t;
    req_was = dut->mem_req;
    auto gate_at = [&](int64_t tt) -> bool {
      // A read is deskewed by `XBUS_ACK_NS` and a write is not, so the model
      // is asked 60 ns before -MEMACK on a read and at it on a write, which is
      // where `Responder::Memory` put its answer.
      if (bus_outstanding)
        return tt >= ack_at_tick -
            (dut->mem_write ? 0
                            : static_cast<int64_t>(kXbusAckNs / kTickNs));
      // Past the trace, and for the channel's own cycles, which muir has no
      // column for: the delay this run was told to charge, from the rise.
      return tt >= static_cast<int64_t>(req_rose_at + mem_delay);
    };
    const bool release = !dut->rst && gate_at(static_cast<int64_t>(t) + 1);

    if (dut->rst) {
      dut->hp0_awready = 0;
      dut->hp0_wready = 0;
      dut->hp0_arready = 0;
      dut->hp0_bvalid = 0;
      dut->hp0_rvalid = 0;
      dut->hp0_rlast = 0;
    } else {
      dut->hp0_awready = dut->hp0_awvalid && !aw_taken;
      dut->hp0_wready = dut->hp0_wvalid && !w_taken;
      dut->hp0_arready = dut->hp0_arvalid && !ar_taken;
      if (aw_taken && w_taken && release) {
        dut->hp0_bvalid = 1;
        dut->hp0_bresp = 0;
      }
      if (ar_taken && release && !dut->hp0_rvalid) {
        // THE BEAT, FETCHED FROM THE STORE AT THE SLAVE'S OWN ADDRESS.  Both
        // words come back: which half the machine takes is
        // `cadr_axi_widen`'s decision and not this model's, and that is the
        // point of the widening being inside the DUT.
        const long w0 = (static_cast<long>(ar_addr) -
                         static_cast<long>(kMainBase)) / 4;
        uint64_t beat = 0;
        if (ar_addr >= kMainBase &&
            ar_addr + 7u < kMainBase + 4ull * kMainWords) {
          uint32_t lo = main_mem[w0], hi = main_mem[w0 + 1];
          // Past the comparison, what an unwritten word of the board's DDR
          // reads as; inside it, muir's zero.  Per word, because a beat can
          // straddle one written word and one that never was.
          if (!touched[w0] && observing) lo = unwritten;
          if (!touched[w0 + 1] && observing) hi = unwritten;
          beat = (static_cast<uint64_t>(hi) << 32) | lo;
        } else {
          // The display's window and anything else outside the 64 MB the
          // machine's 32 memory boards can reach.
          auto it0 = elsewhere.find(ar_addr);
          auto it1 = elsewhere.find(ar_addr + 4u);
          const uint32_t lo = (it0 != elsewhere.end()) ? it0->second : 0u;
          const uint32_t hi = (it1 != elsewhere.end()) ? it1->second : 0u;
          beat = (static_cast<uint64_t>(hi) << 32) | lo;
        }
        dut->hp0_rdata = beat;
        dut->hp0_rresp = 0;
        dut->hp0_rlast = 1;
        dut->hp0_rvalid = 1;
      }
    }

    // ---- the Xbus seam: nothing out there answers ---------------------
    dut->device_rdata = Poison(static_cast<uint32_t>(dut->phys) << 2);

    // ---- the pack side: Linux, and the slave on HP2 --------------------
    //
    // The program runs BEFORE the two faces are driven, so an access it
    // starts this tick is on the bus this tick.  It is handed the interlock
    // the real program reads out of CTL --- whether the walk is standing and
    // which slot it is on --- because the caller already has both and reading
    // CTL for every decision would double the register traffic without
    // changing what is tested.
    if (!dut->rst) {
      feeder.tick(t, dut->req_valid, dut->req_tag, dut->ch_waiting,
                  dut->ch_active && !dut->ch_waiting, dut->ch_slot);
      gp0.drive(dut);
      hp2.drive(dut);
    } else {
      hp2.reset(dut);
      gp0.reset(dut);
    }


    // WHAT THE EDGE WILL SEE, SAMPLED BEFORE IT.  `eval()` at the rising edge
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
    // The bridge's own boundary, in the same breath, so that "inside a
    // request" is decided by the same tick's values.
    const int s_req = dut->mem_req, s_req_write = dut->mem_write;
    const uint32_t s_req_addr = dut->mem_addr;
    const uint32_t s_req_wdata = dut->mem_wdata;

    hp2.sample(dut);
    gp0.sample(dut);

    dut->clk = 1;
    dut->eval();

    if (!dut->rst) {
      hp2.after_edge(dut);
      gp0.after_edge(dut);
    }

    // ---- the slave's books, and the clauses ----------------------------
    //
    // What the store holds at a byte address, by the same rule the read path
    // uses: muir's zero for a word nothing has written inside the comparison,
    // the board's own answer past it.
    auto store_word = [&](uint32_t a) -> uint32_t {
      if (a >= kMainBase && a < kMainBase + 4ull * kMainWords) {
        const size_t w = (a - kMainBase) >> 2;
        if (!touched[w] && observing) return unwritten;
        return main_mem[w];
      }
      auto it = elsewhere.find(a);
      return (it != elsewhere.end()) ? it->second : 0u;
    };
    auto clause = [&](const char *what) {
      if (clause_shown++ < 40) {
        std::printf("AXI CLAUSE BROKEN: %s\n"
                    "    microcycle %" PRIu64 " tick %" PRIu64
                    "  PC %o  OPC %o  VMA %o  MD %08x\n"
                    "    mem_req %d write %d addr %08x wdata %08x"
                    "  ch_active %d wrcyc %d\n",
                    what, fabric_cycles, t, dut->pc, dut->opc, dut->vma,
                    dut->md, s_req, s_req_write, s_req_addr, s_req_wdata,
                    dut->ch_active, dut->wrcyc);
        std::fflush(stdout);
      }
    };

    if (!dut->rst) {
      // ---------------------------------------------- the request window
      if (s_req && !req_last_seen) {
        ++req_rises;
        if (s_req_write) ++req_write_rises; else ++req_read_rises;
        in_request = true;
        req_write = s_req_write;
        req_addr = s_req_addr;
        req_aw = req_ar = req_done = 0;
        req_tick = t;
        if (!bus_outstanding) ++mem_unkeyed;
        if ((s_req_addr & 3u) != 0) ++mem_misaligned;
        // THE DIRECTION IS THE PROCESSOR'S OWN --- while the processor owns
        // the bus.  `cadr_memory_path.sv`'s arbiter gives the channel a word
        // only while the processor is not asking, and `ch_own` is not a port
        // of `cadr_machine`, so a transaction cannot be attributed to an
        // owner from outside while a transfer is in flight.  Rather than
        // widen the clause until it says nothing, it is applied where it is
        // exact and the ticks it skipped are counted and printed.
        if (!dut->ch_active) {
          ++direction_attributable;
          if ((s_req_write != 0) != (dut->wrcyc != 0)) {
            ++direction_wrong;
            clause("the port asks for a direction WRCYC does not name");
          }
        } else {
          ++direction_skipped;
        }
      }
      if (!s_req && req_last_seen && in_request) {
        if (req_done != 1) {
          ++answers_per_request_wrong;
          clause("a request was answered other than exactly once");
        }
        const long want_aw = req_write ? 1 : 0;
        const long want_ar = req_write ? 0 : 1;
        if (req_aw != want_aw || req_ar != want_ar) {
          ++txns_per_request_wrong;
          clause("a request issued other than exactly one transaction of its "
                 "own direction");
        }
        // THE WORD THE MACHINE TOOK BACK IS THE WORD THE STORE HOLDS AT THE
        // ADDRESS THE BRIDGE ASKED FOR.  `cadr_axi_widen` picked the half;
        // this is the whole read path held to one line, and it is the clause
        // a lane taken from the wrong channel falls over.
        if (!req_write) {
          ++words_read_back;
          if (dut->mem_rdata != store_word(req_addr)) {
            ++read_lane_wrong;
            clause("the word read back is not the word the store holds at the "
                   "address the bridge asked for");
          }
        }
        // The histogram the word-store version kept.
        ++cycles_counted;
        if (req_aw + req_ar != 1) {
          ++cycles_multi;
          if (req_aw + req_ar > multi_worst) multi_worst = req_aw + req_ar;
          if (multi_shown < 40) {
            ++multi_shown;
            std::printf("MORE THAN ONE TRANSACTION IN ONE BUS CYCLE: %ld, "
                        "microcycle %" PRIu64 " tick %" PRIu64 "  PC %o  phys %o\n",
                        req_aw + req_ar, fabric_cycles, t, dut->pc,
                        static_cast<unsigned>(dut->phys));
            std::fflush(stdout);
          }
        }
        in_request = false;
      }
      req_last_seen = s_req != 0;

      // ------------------------------------------------- the handshakes
      if (s_awvalid && s_awready) {
        ++aw_handshakes;
        ++mem_writes;
        aw_taken = true;
        aw_addr = s_awaddr;
        committed = false;
        ++req_aw;
        if (!in_request) {
          ++txns_outside_a_request;
          clause("a write went out with no request standing at the port");
        }
        if ((s_awaddr & 7u) != 0) {
          ++beat_unaligned;
          clause("a write address is not a 64-bit beat");
        }
        // A WRITE NOBODY ASKED FOR.  `dev_write` is `cpu_write` straight off
        // the WRCYC flip flop and `ch_active` is the channel's interlock; a
        // write at the port with neither up is a direction invented between
        // the processor and the memory, which is the shape CLAUDE.md's
        // account of the board's page-hash-table word requires.
        if (!dut->dev_write && !dut->ch_active) {
          ++writes_unasked;
          if (writes_unasked_shown < 40) {
            ++writes_unasked_shown;
            std::printf(
                "WRITE NOBODY ASKED FOR  microcycle %" PRIu64 " tick %" PRIu64 "\n"
                "    beat %08x  strobes %02x  data %016" PRIx64 "\n"
                "    PC %o  OPC %o  VMA %o (%08x)  MD %08x\n"
                "    WRCYC %d  dev_write %d  dev_rq %d  phys %o"
                "  ch_active %d ch_waiting %d\n",
                fabric_cycles, t, s_awaddr, s_wstrb, s_wdata,
                dut->pc, dut->opc, dut->vma, dut->vma, dut->md,
                dut->wrcyc, dut->dev_write, dut->dev_rq,
                static_cast<unsigned>(dut->phys),
                dut->ch_active, dut->ch_waiting);
            std::fflush(stdout);
          }
        }
      }
      if (s_wvalid && s_wready) {
        ++w_handshakes;
        w_taken = true;
        w_data = s_wdata;
        w_strb = s_wstrb;
        // THE WIDENING'S CONTRACT, TRANSACTION BY TRANSACTION.  The word is
        // offered in BOTH halves of the beat and the strobes are the four
        // bytes of the half `A[2]` names --- which is what makes the other
        // half untouched by a write that is not addressed to it.
        if (s_wdata != ((static_cast<uint64_t>(s_req_wdata) << 32) |
                        s_req_wdata)) {
          ++wdata_not_offered_twice;
          clause("the beat does not carry the bridge's word in both halves");
        }
        if (s_wstrb != 0x0Fu && s_wstrb != 0xF0u) {
          ++bad_strobes;
          clause("the write strobes are not one half of a beat");
        } else if (s_wstrb != (((req_addr >> 2) & 1u) ? 0xF0u : 0x0Fu)) {
          ++strobe_half_wrong;
          clause("the write strobes name the half the address does not");
        }
      }
      if (aw_taken && w_taken && !committed) {
        committed = true;
        const bool in_main =
            aw_addr >= kMainBase && aw_addr + 7u < kMainBase + 4ull * kMainWords;
        const size_t w0 = (aw_addr - kMainBase) >> 2;
        // THE WATCHPOINT, ON THE BEAT.
        const bool watch_lo = in_main && w0 < kMainWords && watched[w0];
        const bool watch_hi = in_main && w0 + 1 < kMainWords && watched[w0 + 1];
        if (watch_lo || watch_hi) {
          ++watch_hits;
          ++watch_writes;
          std::printf(
              "WATCH WRITE  beat %08x (physical words %o and %o)"
              "  microcycle %" PRIu64 "  tick %" PRIu64 "\n"
              "    strobes %02x -> the %s half   data %016" PRIx64 "\n"
              "    the words there were %08x and %08x%s\n"
              "    the bridge asked for %08x = physical %o, wdata %08x\n"
              "    PC %o  OPC %o  LPC %o  IR %012" PRIx64 "\n"
              "    VMA %o (%08x)   MD %08x   OB %08x\n"
              "    WRCYC %d  dev_write %d  dev_rq %d  device %d"
              "  phys %o  ch_active %d ch_waiting %d\n",
              aw_addr, static_cast<unsigned>(w0), static_cast<unsigned>(w0 + 1),
              fabric_cycles, t, w_strb, (w_strb == 0xF0u) ? "high" : "low",
              w_data, in_main ? main_mem[w0] : 0u,
              in_main ? main_mem[w0 + 1] : 0u,
              (in_main && (touched[w0] || touched[w0 + 1]))
                  ? "" : "  (nothing had written them)",
              req_addr, static_cast<unsigned>((req_addr - kMainBase) >> 2),
              req_wdata_at_aw,
              dut->pc, dut->opc, dut->lpc, static_cast<uint64_t>(dut->ir),
              dut->vma, dut->vma, dut->md, dut->ob,
              dut->wrcyc, dut->dev_write, dut->dev_rq, dut->device,
              static_cast<unsigned>(dut->phys),
              dut->ch_active, dut->ch_waiting);
          std::fflush(stdout);
          // THE TRIPWIRE: the board's own word, by its VALUE.  Every one of
          // the page hash table's 8,019 other valid entries has top byte
          // `0x0A`; the corrupted one has `0x26`, the Lisp data type of a raw
          // virtual address.
          const uint32_t half = (w_strb == 0xF0u)
              ? static_cast<uint32_t>(w_data >> 32)
              : static_cast<uint32_t>(w_data);
          if ((half >> 24) != 0x0Au)
            std::printf("*** A WORD THAT IS NOT A PAGE HASH TABLE WORD: %08x, "
                        "top byte %02x where the table's is 0a ***\n",
                        half, half >> 24);
          std::fflush(stdout);
        }
        if (in_main) {
          uint32_t lo = main_mem[w0], hi = main_mem[w0 + 1];
          const uint32_t was_lo = lo, was_hi = hi;
          uint64_t beat = (static_cast<uint64_t>(hi) << 32) | lo;
          for (int b = 0; b < 8; ++b)
            if (w_strb & (1u << b)) {
              const uint64_t msk = 0xFFULL << (8 * b);
              beat = (beat & ~msk) | (w_data & msk);
            }
          lo = static_cast<uint32_t>(beat);
          hi = static_cast<uint32_t>(beat >> 32);
          // A WRITE DISTURBS ONLY ITS OWN HALF, held by DATA and not by the
          // strobe pattern alone: the neighbouring word of the beat is a real
          // and different word of the machine's memory, and a strobe covering
          // it destroys it silently.
          const bool hi_half = ((req_addr >> 2) & 1u) != 0;
          if (hi_half ? (lo != was_lo) : (hi != was_hi)) {
            ++neighbour_disturbed;
            clause("a write disturbed the other half of its beat");
          }
          main_mem[w0] = lo;
          main_mem[w0 + 1] = hi;
          if (w_strb & 0x0Fu) touched[w0] = 1;
          if (w_strb & 0xF0u) touched[w0 + 1] = 1;
        } else {
          ++mem_outside;
          ++outside_the_store;
          // The display's window, a word of the beat at a time.
          if (w_strb & 0x0Fu) elsewhere[aw_addr] = static_cast<uint32_t>(w_data);
          if (w_strb & 0xF0u)
            elsewhere[aw_addr + 4u] = static_cast<uint32_t>(w_data >> 32);
        }
      }
      if (s_arvalid && s_arready) {
        ++ar_handshakes;
        ++mem_reads;
        ar_taken = true;
        ar_addr = s_araddr;
        ++req_ar;
        if (!in_request) {
          ++txns_outside_a_request;
          clause("a read went out with no request standing at the port");
        }
        if ((s_araddr & 7u) != 0) {
          ++beat_unaligned;
          clause("a read address is not a 64-bit beat");
        }
        const bool in_main =
            s_araddr >= kMainBase && s_araddr + 7u < kMainBase + 4ull * kMainWords;
        if (!in_main) ++mem_outside;
        else {
          const size_t sel = (req_addr - kMainBase) >> 2;
          if (sel < kMainWords && !touched[sel]) ++mem_untouched_reads;
        }
        const size_t w0 = in_main ? ((s_araddr - kMainBase) >> 2) : 0;
        const bool watch_lo = in_main && w0 < kMainWords && watched[w0];
        const bool watch_hi = in_main && w0 + 1 < kMainWords && watched[w0 + 1];
        if (watch_lo || watch_hi) {
          ++watch_hits;
          ++watch_reads;
          std::printf(
              "WATCH read   beat %08x (physical words %o and %o)"
              "  microcycle %" PRIu64 "  tick %" PRIu64 "\n"
              "    the words there are %08x and %08x%s\n"
              "    the bridge asked for %08x = physical %o\n"
              "    PC %o  OPC %o  LPC %o  IR %012" PRIx64 "\n"
              "    VMA %o (%08x)   MD %08x   OB %08x\n"
              "    WRCYC %d  dev_write %d  dev_rq %d  device %d"
              "  phys %o  ch_active %d ch_waiting %d\n",
              s_araddr, static_cast<unsigned>(w0), static_cast<unsigned>(w0 + 1),
              fabric_cycles, t, main_mem[w0], main_mem[w0 + 1],
              (touched[w0] || touched[w0 + 1]) ? ""
                                               : "  (nothing had written them)",
              req_addr, static_cast<unsigned>((req_addr - kMainBase) >> 2),
              dut->pc, dut->opc, dut->lpc, static_cast<uint64_t>(dut->ir),
              dut->vma, dut->vma, dut->md, dut->ob,
              dut->wrcyc, dut->dev_write, dut->dev_rq, dut->device,
              static_cast<unsigned>(dut->phys),
              dut->ch_active, dut->ch_waiting);
          std::fflush(stdout);
        }
      }
      if (s_bvalid && s_bready) {
        ++b_handshakes;
        ++req_done;
        dut->hp0_bvalid = 0;
        aw_taken = w_taken = false;
      }
      if (s_rvalid && s_rready) {
        if (s_rlast) { ++r_handshakes; ++req_done; }
        dut->hp0_rvalid = 0;
        dut->hp0_rlast = 0;
        ar_taken = false;
      }
      // The word the bridge is offering while the write's address is on the
      // channel, kept for the watchpoint's report.
      if (s_req && s_req_write) req_wdata_at_aw = s_req_wdata;
    }

    if (bus_outstanding && !dut->mem_req && !dut->dev_rq &&
        static_cast<int64_t>(t) > ack_at_tick)
      bus_outstanding = false;

    // A transfer has written a slot: the pack holds the block only once this
    // side has taken it out again.
    if (dut->ch_wrote) feeder.wrote(dut->ch_slot);
    if (dut->ch_hit) feeder.hit(dut->ch_slot, t);

    // What a transfer costs the fabric, which is the whole of what muir's
    // channel does not do: `Controller::transfer` writes `main` directly and
    // finishes at the instant it started.
    if (dut->ch_active && !ch_was) { ch_up_at = t; ch_up_cycle = fabric_cycles; }
    if (!dut->ch_active && ch_was) {
      const long ticks = static_cast<long>(t - ch_up_at);
      // A START that starts no walk raises `ch_active` for two ticks.
      if (ticks > 8) {
        ++transfers;
        ch_ticks_total += ticks;
        ch_cycles_total += static_cast<long>(fabric_cycles - ch_up_cycle);
        if (ticks > ch_longest) ch_longest = ticks;
      }
    }
    ch_was = dut->ch_active;

    // ------------------------------------------- the halt, and its fingerprint
    //
    // THE BOARD'S OWN FINGERPRINT, from CLAUDE.md: `PC 0o23555` with
    // `OPC 0o23560` is `PGF-W-1+7` having returned into the `DISPATCH-XCT-NEXT
    // MAP-STATUS-CODE` at `0o23553` and landed on case 4, which `D-PGF` sends
    // to `ILLOP`.  A write fault whose map says the page is writable.
    if (dut->clock_edge) {
      if (dut->pc == 0023555u && dut->opc == 0023560u) {
        ++fingerprint_hits;
        if (fingerprint_hits <= 4) {
          std::printf(
              "THE BOARD'S FINGERPRINT: PC %o OPC %o at microcycle %" PRIu64
              " (tick %" PRIu64 ")\n    VMA %o (%08x)  MD %08x  Q %08x\n",
              dut->pc, dut->opc, fabric_cycles, t,
              dut->vma, dut->vma, dut->md, dut->q);
          std::fflush(stdout);
        }
      }
      if (dut->pc == 0024074u) ++visits_pgf_rl;
      if (dut->pc == 0024077u) ++visits_pgf_rl_read;
      if (dut->pc == 0024047u) ++visits_pgf_rwf;
      if (dut->pc == 0023551u) ++visits_pgf_w1;
      quiet_since = t;
      if (progress && fabric_cycles % progress == 0) {
        std::printf("... microcycle %" PRIu64 "  tick %" PRIu64 "  PC %o  MD %08x\n"
                    "      %ld served, %ld transfers, %ld bus cycles, "
                    "%ld unasked writes, %ld multi-txn, %ld denials, %ld written back\n"
                    "      req_valid %d req_tag %08x (unit %u  c %u h %u b %u)"
                    "  ch_active %d ch_waiting %d ch_slot %d store_miss %d  Linux %d\n",
                    fabric_cycles, t, dut->pc, dut->md, feeder.served, transfers,
                    cycles_counted, writes_unasked, cycles_multi, feeder.denied,
                    feeder.written_back,
                    dut->req_valid, dut->req_tag,
                    (dut->req_tag >> 28) & 7u, (dut->req_tag >> 16) & 0xFFFu,
                    (dut->req_tag >> 8) & 0xFFu, dut->req_tag & 0xFFu,
                    dut->ch_active, dut->ch_waiting, dut->ch_slot,
                    dut->store_miss, static_cast<int>(feeder.st));
        std::printf("      %ld reads of words nothing had written, answered "
                    "%08x\n", mem_untouched_reads, unwritten);
        for (uint32_t wd : watch_words)
          if (wd < kMainWords)
            std::printf("      physical %o holds %08x%s\n", wd, main_mem[wd],
                        (main_mem[wd] >> 24) == 0x26u
                            ? "   *** TOP BYTE 26: THE BOARD'S SIGNATURE ***"
                            : "");
        {
          // THE SCREEN.  `cadr_xbus_ddr` answers the display's window at
          // `DISPLAY_BASE`, so every frame-buffer word the machine writes is
          // in `elsewhere`.  CLAUDE.md dates muir's painting: the first pixel
          // at microcycle 1,422,167, the first CHARACTER at 4,441,390, the
          // picture complete at about 6,880,000 --- and the BOARD, at its
          // halt 169 million microcycles in, has never painted a character.
          // So this number is the instrument that says whether the fabric is
          // following muir's program or the board's.
          long lit_words = 0, lit_bits = 0;
          for (const auto &kv : elsewhere) {
            if (kv.second) {
              ++lit_words;
              lit_bits += __builtin_popcount(kv.second);
            }
          }
          std::printf("      the screen: %ld words written, %ld of them "
                      "non-zero, %ld lit pixels\n",
                      static_cast<long>(elsewhere.size()), lit_words, lit_bits);
        }
        if (feeder.declined_already_held)
          std::printf("      %ld refills declined (the store already had the "
                      "block)\n", feeder.declined_already_held);
        std::printf("      the seam: %ld GP0 writes, %ld reads; HP2 %ld read "
                    "bursts / %ld beats, %ld write bursts / %ld beats; "
                    "%ld refusals, %ld errors\n",
                    gp0.writes, gp0.reads, hp2.read_bursts, hp2.read_beats,
                    hp2.write_bursts, hp2.write_beats, feeder.refusals,
                    feeder.errors);
        std::fflush(stdout);
      }
    }
    // A machine that retires no microcycle for a long time has stopped.  A
    // memory stall is tens of ticks and a disk wait is a wait for an
    // interrupt, which still runs microcycles, so this only fires on a halt.
    if (!halted && quiet_since && t - quiet_since > halt_quiet) {
      halted = true;
      halt_cycle = fabric_cycles;
      stopped_because = "the machine stopped retiring microcycles";
      std::printf(
          "THE MACHINE STOPPED: no microcycle for %" PRIu64 " ticks, at "
          "microcycle %" PRIu64 " (tick %" PRIu64 ")\n"
          "    PC %o  OPC %o  LPC %o  IR %012" PRIx64 "\n"
          "    VMA %o (%08x)  MD %08x  Q %08x  OB %08x  -VMAOK %d\n",
          halt_quiet, halt_cycle, t, dut->pc, dut->opc, dut->lpc,
          static_cast<uint64_t>(dut->ir), dut->vma, dut->vma,
          dut->md, dut->q, dut->ob, !dut->vmaok);
      std::fflush(stdout);
      break;
    }

    if (dut->clock_edge && observing) {
      ++fabric_cycles;
      if (!fabric_promdis_at && dut->promdisable) fabric_promdis_at = fabric_cycles;
    } else if (dut->clock_edge) {
      ++fabric_cycles;
      if (!fabric_promdis_at && dut->promdisable) fabric_promdis_at = fabric_cycles;
      const Row &r = cur;
      const Sample &s = prev;

      bool agree =
          s.pc == r.v[kPc] && s.ir == r.v[kIr] && s.lpc == r.v[kLpc] &&
          s.opc == r.v[kOpc] && s.st == r.v[kSt] && s.lc == r.v[kLc] &&
          s.a == r.v[kA] && s.m == r.v[kM] && s.alu == r.v[kAlu] &&
          s.r == r.v[kR] && s.ob == r.v[kOb] && s.q == r.v[kQ] &&
          s.dc == r.v[kDc] && s.vma == r.v[kVma] && s.md == r.v[kMd] &&
          (s.vmaok != r.v[kNVmaok]) && s.jcond == r.v[kJcond] &&
          s.nop == r.v[kNop] && s.pcs1 == r.v[kPcs1] && s.pcs0 == r.v[kPcs0] &&
          s.iwrited == r.v[kIwrited] && s.promdis == r.v[kPromdis] &&
          s.sintr == r.v[kSintr];

      // A DISAGREEMENT THAT MUST BE OVER IN A BOUNDED NUMBER OF MICROCYCLES.
      //
      // The two machines keep one clock to within a few hundred nanoseconds
      // when the drive's time is charged on both sides, and a few hundred
      // nanoseconds is still enough to put the spindle on the other side of a
      // sector boundary: the drive's block counter is `STATUS<27:24>`, the
      // region under the head, and the two then read one apart.  That is a
      // difference of INSTANT and not of the machine, it goes into MD and out
      // through the ALU, and it is gone as soon as the microcode has masked
      // the bit it wanted.
      //
      // **What this may not be used to hide, and what says so.**  Every burst
      // is counted, its length is bounded, and the columns it touched are
      // printed with the exclusive-or of the MD difference --- so a burst that
      // is NOT the spindle's four bits shows as a different mask, and a
      // difference that does not end shows as a failure.  The check asserts
      // both at the end.  It is `machine.pass`'s nanosecond slip met one level
      // up, where the slip has become visible.
      bool tolerating = false;
      if (!agree && tolerate > 0) {
        if (!in_burst) {
          in_burst = true;
          ++bursts;
          burst_len = 0;
          burst_at = r.v[kCycle];
          burst_mask = 0;
          burst_cols = 0;
        }
        ++burst_len;
        ++tolerated;
        burst_mask |= s.md ^ static_cast<uint32_t>(r.v[kMd]);
        if (s.pc != r.v[kPc]) burst_cols |= 1;
        if (s.ir != r.v[kIr]) burst_cols |= 2;
        if (s.vma != r.v[kVma]) burst_cols |= 4;
        if (s.vmaok == r.v[kNVmaok]) burst_cols |= 8;
        if (s.sintr != r.v[kSintr]) burst_cols |= 16;
        if (burst_len > tolerate) {
          std::fprintf(stderr,
                       "\nFAIL: the fabric and muir were still apart %ld microcycles "
                       "after reference microcycle %" PRIu64 "\n", burst_len, burst_at);
          ++bad;
          stopped_because = "a disagreement outlasted --tolerate";
          break;
        }
        // LOCKSTEP, not a catch-up: the two machines are executing the same
        // microcycle and disagreeing about a value in it, so the reference
        // advances with the fabric.
        tolerating = true;
      }

      if (!agree && !tolerating && absorb_cap > 0) {
        // THE MACHINE MAY TAKE LONGER, AND MUST ARRIVE IN THE SAME STATE.
        //
        // `--absorb` holds the reference row where it is and lets the fabric
        // run until its WHOLE sample is that row again.  **Measured, and it
        // does not work here**: a machine that has been round a wait loop
        // extra times carries that in `OPC` and `LPC`, which are the eighth
        // and first stages of the shift register of past PCs, so the state it
        // arrives in is not the reference row and never becomes it.  Kept as
        // an instrument, with the near misses printed, because what it prints
        // is the reason.
        if (!catching_up) {
          catching_up = true;
          ++absorb_runs;
          absorb_run = 0;
          if (!first_absorb) first_absorb = r.v[kCycle];
        }
        ++absorbed;
        ++absorb_run;
        absorb_pc[s.pc]++;
        // WHAT KEEPS THE FABRIC FROM ARRIVING.  A run that does not rejoin is
        // a failure, and the useful half of it is which column is still wrong
        // when the machine is back at the same microinstruction.
        if (s.pc == r.v[kPc] && near_misses < 6) {
          ++near_misses;
          std::fprintf(stderr,
                       "  near miss %ld: the fabric is back at PC %o after %ld "
                       "absorbed microcycles, and still differs in:",
                       near_misses, s.pc, absorb_run);
          auto dif = [&](const char *w, uint64_t g, uint64_t want) {
            if (g != want) std::fprintf(stderr, " %s(%" PRIx64 "/%" PRIx64 ")", w, g, want);
          };
          dif("IR", s.ir, r.v[kIr]); dif("LPC", s.lpc, r.v[kLpc]);
          dif("OPC", s.opc, r.v[kOpc]); dif("ST", s.st, r.v[kSt]);
          dif("LC", s.lc, r.v[kLc]); dif("A", s.a, r.v[kA]);
          dif("M", s.m, r.v[kM]); dif("ALU", s.alu, r.v[kAlu]);
          dif("R", s.r, r.v[kR]); dif("OB", s.ob, r.v[kOb]);
          dif("Q", s.q, r.v[kQ]); dif("DC", s.dc, r.v[kDc]);
          dif("VMA", s.vma, r.v[kVma]); dif("MD", s.md, r.v[kMd]);
          dif("-VMAOK", !s.vmaok, r.v[kNVmaok]); dif("JCOND", s.jcond, r.v[kJcond]);
          dif("NOP", s.nop, r.v[kNop]); dif("PCS1", s.pcs1, r.v[kPcs1]);
          dif("PCS0", s.pcs0, r.v[kPcs0]); dif("IWRITED", s.iwrited, r.v[kIwrited]);
          dif("PROMDIS", s.promdis, r.v[kPromdis]); dif("SINTR", s.sintr, r.v[kSintr]);
          std::fprintf(stderr, "\n");
        }
        if (absorb_run > absorb_longest) absorb_longest = absorb_run;
        if (absorb_run > absorb_cap) {
          std::fprintf(stderr,
                       "\nFAIL: the fabric ran %ld microcycles past reference "
                       "microcycle %" PRIu64 " (PC %o) without arriving at it\n",
                       absorb_run, r.v[kCycle], s.pc);
          ++bad;
          stopped_because = "the fabric never rejoined the reference";
          break;
        }
      } else {
        if (agree && in_burst) {
          in_burst = false;
          if (burst_len > burst_longest) burst_longest = burst_len;
          burst_masks[burst_mask] += 1;
          burst_where[burst_cols] += 1;
        }
        if (catching_up) catching_up = false;
        absorb_run = 0;
        // THE TWO CLOCKS, measured on every row the two machines agree on.
        // The first row has no predecessor to take a length from; from the
        // second on, every microcycle's length is compared with muir's and the
        // difference accumulated, so the figure printed is a sum of per-row
        // differences and not an offset carried from the reset.
        if (!clock_started) {
          clock_started = true;
        } else {
          const int64_t fab = static_cast<int64_t>((t - last_edge_tick) * 5ull);
          const int64_t mu = static_cast<int64_t>(r.v[kNs] - last_muir_ns);
          if (r.v[kStall]) { drift_stalled += fab - mu; ++rows_stalled; }
          else { drift_plain += fab - mu; ++rows_plain; }
        }
        last_edge_tick = t;
        last_muir_ns = r.v[kNs];
        if ((r.v[kCycle] % 100000) == 0)
          drift_marks.emplace_back(r.v[kCycle], drift_stalled + drift_plain);

        if (!agree && !tolerating) {
          std::fprintf(stderr,
                       "\n      the comparison ENDS at reference microcycle %" PRIu64
                       " (the fabric's %" PRIu64 ", tick %" PRIu64 ")\n",
                       r.v[kCycle], fabric_cycles, t);
          std::fprintf(stdout,
                       "    the two clocks: the fabric is at %" PRIu64 " ns and muir "
                       "at %" PRIu64 " ns, a difference of %" PRId64 " ns\n"
                       "    the drive's turn: the fabric %" PRIu64 " ns into it, "
                       "muir %" PRIu64 " ns, blocks %" PRIu64 " and %" PRIu64 "\n",
                       static_cast<uint64_t>(t * 5ull), r.v[kNs],
                       static_cast<int64_t>(t * 5ull) - static_cast<int64_t>(r.v[kNs]),
                       static_cast<uint64_t>((t * 5ull) % 16666667ull),
                       static_cast<uint64_t>(r.v[kNs] % 16666667ull),
                       static_cast<uint64_t>(((t * 5ull) % 16666667ull) / 968448ull),
                       static_cast<uint64_t>((r.v[kNs] % 16666667ull) / 968448ull));
          auto one = [&](const char *what, uint64_t got, uint64_t want) {
            if (got != want)
              std::fprintf(stdout, "    %-12s fabric %" PRIx64 "   muir %" PRIx64 "\n",
                           what, got, want);
          };
          one("PC (octal)", s.pc, r.v[kPc]);
          std::fprintf(stdout, "    PC          fabric %o   muir %o\n",
                       s.pc, static_cast<unsigned>(r.v[kPc]));
          one("IR", s.ir, r.v[kIr]);
          one("LPC", s.lpc, r.v[kLpc]);
          one("OPC", s.opc, r.v[kOpc]);
          one("ST", s.st, r.v[kSt]);
          one("LC", s.lc, r.v[kLc]);
          one("A", s.a, r.v[kA]);
          one("M", s.m, r.v[kM]);
          one("ALU", s.alu, r.v[kAlu]);
          one("R", s.r, r.v[kR]);
          one("OB", s.ob, r.v[kOb]);
          one("Q", s.q, r.v[kQ]);
          one("DC", s.dc, r.v[kDc]);
          one("VMA", s.vma, r.v[kVma]);
          one("MD", s.md, r.v[kMd]);
          one("-VMAOK", !s.vmaok, r.v[kNVmaok]);
          one("JCOND", s.jcond, r.v[kJcond]);
          one("NOP", s.nop, r.v[kNop]);
          one("PCS1", s.pcs1, r.v[kPcs1]);
          one("PCS0", s.pcs0, r.v[kPcs0]);
          one("IWRITED", s.iwrited, r.v[kIwrited]);
          one("PROMDISABLE", s.promdis, r.v[kPromdis]);
          one("SINTR", s.sintr, r.v[kSintr]);
          std::fprintf(stdout,
                       "    VMA octal   fabric %o   muir %o\n"
                       "    the machine: ch_active %d ch_waiting %d store_miss %d "
                       "promdisable %d\n",
                       s.vma, static_cast<unsigned>(r.v[kVma]),
                       dut->ch_active, dut->ch_waiting, dut->store_miss,
                       dut->promdisable);
          // NOT a failure in itself: where the two part is the reference's
          // shape, and the floor below is what a regression breaks.
          stopped_because = "the fabric and muir disagree";
          if (observe) {
            observing = true;
            observe_until = fabric_cycles + observe;
            std::fprintf(stderr,
                         "    --observe: the comparison ends here; the fabric runs "
                         "%" PRIu64 " more microcycles on its own\n", observe);
          } else {
            break;
          }
        }
        // WHERE muir's OWN INTERFACE ANSWERS THIS CYCLE.  Rounded up, for
        // the reason `tb/cadr_machine_tb.cpp` gives: muir's acknowledgement is
        // not on the five-nanosecond grid and the fabric can only see it at a
        // tick at or after it.
        if (r.v[kBus]) {
          bus_outstanding = true;
          ack_at_tick = static_cast<int64_t>(t) +
              static_cast<int64_t>((ack_for[k] - r.v[kNs] + kTickNs - 1) / kTickNs);
        }

        // Aligned: take the next reference row.  Not when the comparison has
        // just ended, so that both modes report the same figure for how far
        // it got.
        //
        // **AND NOT WITH A `continue`, WHICH IS WHAT THIS FILE'S PARENT DOES
        // AND WHAT COST AN AFTERNOON HERE.**  The loop's last statement is
        // `dut->clk = 0`.  A `continue` at this point skips it, so the next
        // iteration sets `clk = 1` on a clock that is ALREADY 1, `eval()` sees
        // no positive edge, and THE DESIGN LOSES ONE WHOLE TICK --- once, at
        // the instant the comparison ends --- while every state machine on the
        // testbench's side runs that tick as though it had happened.
        //
        // In `tb/cadr_band_axi_tb.cpp` and `tb/cadr_hash_watch_tb.cpp` that is
        // invisible, because the only thing on their side of a handshake is an
        // `S_AXI_HP0` slave that is idle at that instant.  Here Linux and the
        // pack side are mid-conversation on two more ports: measured, the GP0
        // master took an R beat at that lost edge and the pack side never gave
        // it, so the slave stood in R_DATA with RVALID up and the master in
        // R_ADDR with ARVALID up FOR EVER --- and the symptom a million
        // microcycles later was only that the machine waited for a block,
        // which reads exactly like a disk that will not answer.
        //
        // The `continue` was never about the clock, so this says what it means
        // instead: do not take the next row.
        if (!observing) {
          ++k;
          if (k < total_rows && !read_next(cur)) {
            std::fprintf(stderr, "FAIL: %s: ran out of rows at %" PRIu64 " of %"
                         PRIu64 "\n", trace_path, k, total_rows);
            ++fails;
            break;
          }
        }
      }

    }

    dut->clk = 0;
    dut->eval();
    prev = take();
  }
  if (!stopped_because && t >= max_ticks) stopped_because = "the tick budget ran out";

  // ===================== THE READOUT, AT WHATEVER STATE IT STOPPED IN =======
  //
  // `cadr_microcycle.sv`'s readout window: `ro_addr` is `{sel<3:0>,
  // word<13:0>}` and the answer is three ticks behind.  The machine is
  // halted here, so nothing moves under it.
  {
    auto ro = [&](unsigned sel, unsigned word) -> uint64_t {
      dut->con_ro_addr = (sel << 14) | (word & 0x3FFFu);
      for (int i = 0; i < 8; ++i) {
        dut->clk = 1; dut->eval();
        dut->clk = 0; dut->eval();
      }
      return static_cast<uint64_t>(dut->con_ro_data);
    };
    constexpr unsigned kRoMap1 = 7, kRoMap2 = 8, kRoOpcs = 9;
    std::printf("\n---- the machine's own memories, read back through the console window\n");
    std::printf("    map2[777] = %06" PRIx64 "        (the board reads 4FC9F9)\n",
                ro(kRoMap2, 0777) & 0xFFFFFFull);
    std::printf("    the OPC stack, newest first:");
    for (unsigned i = 0; i < 8; ++i)
      std::printf(" %o", static_cast<unsigned>(ro(kRoOpcs, i) & 0x3FFFull));
    std::printf("\n");
    // The page the board faults on, for whoever comes after: VMA 0o2640010 is
    // page 2880, whose level-1 block is VMA<23:13>.
    std::printf("    map1[%o] = %02" PRIx64 "   map1[%o] = %02" PRIx64 "\n",
                (dut->vma >> 13) & 0x7FFu,
                ro(kRoMap1, (dut->vma >> 13) & 0x7FFu) & 0x1Full,
                0x131u, ro(kRoMap1, 0x131) & 0x1Full);
  }

  // ===================== WHAT THE THREE INSTRUMENTS SAW =====================
  std::printf(
      "\n---- the watchpoint\n"
      "    %ld watched words; %ld transactions touched one, %ld reads and %ld writes\n"
      "---- one transaction per bus cycle\n"
      "    %ld bus cycles at the bridge, %ld of them with more than one "
      "transaction (worst %ld)\n"
      "---- a write nobody asked for\n"
      "    %ld writes at the bridge with the processor's WRCYC down and the "
      "channel idle\n"
      "---- the suspect path\n"
      "    PGF-RL (0o24074) %ld visits, its read at 0o24077 %ld, "
      "PGF-RWF (0o24047) %ld, PGF-W-1 (0o23551) %ld\n"
      "---- the fingerprint\n"
      "    PC 23555 with OPC 23560 reached %ld times; the machine %s\n",
      static_cast<long>(watch_words.size()), watch_hits, watch_reads, watch_writes,
      cycles_counted, cycles_multi, multi_worst,
      writes_unasked,
      visits_pgf_rl, visits_pgf_rl_read, visits_pgf_rwf, visits_pgf_w1,
      fingerprint_hits, halted ? "stopped" : "was still running");

  // ============ WHAT THE 64-BIT PORT DID, WHICH IS THIS FILE'S OWN =========
  std::printf(
      "---- the port, which `tb/cadr_hash_watch_tb.cpp` has no view of at all\n"
      "    %ld requests at the bridge (%ld reads, %ld writes)\n"
      "    %ld AR and %ld AW handshakes, %ld W beats, %ld R-last and %ld B\n"
      "    %ld words read back and compared against the store at the bridge's "
      "own address\n"
      "    the direction was attributable on %ld requests and skipped on %ld "
      "with a transfer in flight\n"
      "    clauses broken: answers-per-request %ld, transactions-per-request "
      "%ld,\n"
      "      outside-a-request %ld, direction %ld, beat-unaligned %ld,\n"
      "      strobes-not-a-half %ld, strobes-name-the-wrong-half %ld,\n"
      "      word-not-offered-twice %ld, read-lane %ld, neighbour-disturbed "
      "%ld\n"
      "    %ld transactions landed outside the modelled store (the display's "
      "window)\n",
      req_rises, req_read_rises, req_write_rises,
      ar_handshakes, aw_handshakes, w_handshakes, r_handshakes, b_handshakes,
      words_read_back, direction_attributable, direction_skipped,
      answers_per_request_wrong, txns_per_request_wrong,
      txns_outside_a_request, direction_wrong, beat_unaligned,
      bad_strobes, strobe_half_wrong, wdata_not_offered_twice,
      read_lane_wrong, neighbour_disturbed, outside_the_store);

  dut->final();
  delete dut;
  std::fclose(f);

  fails += bad;

  std::printf(
      "band-axi: %" PRIu64 " of %" PRIu64 " reference microcycles compared, "
      "the fabric running %" PRIu64 " of its own in %" PRIu64 " ticks\n",
      k, total_rows, fabric_cycles, t);
  if (stopped_because) std::printf("      stopped: %s\n", stopped_because);
  std::printf(
      "      main memory: %ld reads and %ld writes through mem_*, %ld reads of\n"
      "        words nothing had written (muir's memory is zero there too),\n"
      "        %ld cycles outside main memory, %ld not word-aligned, %ld answered\n"
      "        as soon as asked because muir's channel makes no bus cycle for them\n"
      "      the pack: %ld blocks served from the image and %ld from what the\n"
      "        machine had written, %ld blocks written back over %ld evictions,\n"
      "        %zu distinct blocks written, %ld fills, %ld denials\n"
      "      the walk waited %ld ticks for a block over %ld fills, the longest %ld\n",
      mem_reads, mem_writes, mem_untouched_reads, mem_outside, mem_misaligned,
      mem_unkeyed,
      pack.served_image(), pack.served_written(), pack.written_blocks(),
      feeder.written_back, pack.distinct_written(), feeder.served,
      feeder.denied,
      feeder.serve_ticks, feeder.served, feeder.longest_serve);
  std::printf(
      "      the two clocks, over the %ld agreeing microcycles the fabric and muir\n"
      "        both ran: %+" PRId64 " ns in total, %+" PRId64 " ns over %ld stalled\n"
      "        microcycles and %+" PRId64 " ns over %ld unstalled ones\n",
      rows_stalled + rows_plain, drift_stalled + drift_plain,
      drift_stalled, rows_stalled, drift_plain, rows_plain);
  if (!drift_marks.empty()) {
    std::printf("        cumulative, every hundred thousand microcycles:");
    for (size_t i = 0; i < drift_marks.size(); ++i)
      std::printf("%s %" PRIu64 ":%+" PRId64, (i % 4) ? "" : "\n         ",
                  drift_marks[i].first, drift_marks[i].second);
    std::printf("\n");
  }
  if (observe) {
    std::printf(
        "      --observe, the fabric on its own past the comparison:\n"
        "        %ld transfers, %ld ticks and %ld microcycles inside ch_active in\n"
        "          total, the longest %ld ticks --- muir's channel spends NONE of\n"
        "          either, `Controller::transfer` writing main memory directly\n"
        "        PROMDISABLE rose at the fabric's microcycle %" PRIu64
        " (muir: 1410035)\n",
        transfers, ch_ticks_total, ch_cycles_total, ch_longest, fabric_promdis_at);
  }
  if (tolerate > 0) {
    std::printf(
        "      disagreements tolerated, each bounded at %ld microcycles: %ld of them,\n"
        "        %ld microcycles in all, the longest %ld\n",
        tolerate, bursts, tolerated, burst_longest);
    for (auto &m : burst_masks)
      std::printf("        MD differed by %08x in %ld of them%s\n", m.first, m.second,
                  (m.first & ~0x1F000000u) ? "   <-- NOT ONLY THE SPINDLE'S REGION"
                                           : "   (STATUS<28:24>, the spindle's region)");
    for (auto &w : burst_where)
      if (w.first)
        std::printf("        %ld of them also moved%s%s%s%s%s\n", w.second,
                    (w.first & 1) ? " PC" : "", (w.first & 2) ? " IR" : "",
                    (w.first & 4) ? " VMA" : "", (w.first & 8) ? " -VMAOK" : "",
                    (w.first & 16) ? " SINTR" : "");
  }
  if (absorb_cap > 0) {
    std::printf(
        "      absorbed while the fabric caught up: %ld microcycles in %ld runs,\n"
        "        the longest %ld, the first at reference microcycle %" PRIu64 "\n"
        "        at microcode addresses:",
        absorbed, absorb_runs, absorb_longest, first_absorb);
    int shown = 0;
    for (auto &p : absorb_pc) {
      if (shown++ >= 12) { std::printf(" ..."); break; }
      std::printf(" %o(%ld)", p.first, p.second);
    }
    std::printf("\n");
  }

  // ------------------------------------------------------ what is asserted
  //
  // The divergence itself is NOT asserted: it is the reference's shape and
  // not the fabric's, and a check that required it would be a photograph of
  // today rather than a comparison.  What is asserted is everything a
  // regression would break.
  if (!observing) {
    Check(k >= floor,
          "%" PRIu64 " microcycles of the band agree with muir, wanting at least "
          "%" PRIu64 "; the header says what the figure is and where it came from",
          k, floor);
    // **THE TWO CLOCKS.**  Nothing else in this repository asserts this: every
    // other check re-anchors to the trace's own `ns` at every row and exempts a
    // sub-tick slip, so an absolute difference has never had to be nil.  Here
    // it does, because the machine now reads things that are a function of the
    // instant it is at --- the drive's spindle, the I/O board's microsecond
    // counter --- and a drift of a few hundred nanoseconds is enough to move
    // the first of them.
    Check(drift_stalled + drift_plain == 0,
          "the fabric's clock and muir's are %+" PRId64 " ns apart over the "
          "%ld microcycles they agreed on, wanting nil",
          drift_stalled + drift_plain, rows_stalled + rows_plain);
    // The boot PROM's own main-memory traffic, which `map_boot.pass` holds on
    // the other trace: one read and one write of each of page 0's 256 words.
    // Asserted as a floor here because a drive on the cable takes the program
    // past the parity loop and it makes a few more.
    Check(mem_reads >= 256 && mem_writes >= 256,
          "%ld main-memory reads and %ld writes, wanting at least 256 of each",
          mem_reads, mem_writes);
    Check(mem_misaligned == 0, "%ld transactions were not word-aligned",
          mem_misaligned);
    // **A BLOCK OF THE PACK, FETCHED AT THE ADDRESS THE CONTROLLER ITSELF
    // POSTED --- AND ITS CONTENT IS NOT CHECKED HERE.**  Without this the run
    // could reach the floor with the disk seam never used at all.  With it,
    // what is held is that the seam ran and the address came from the fabric.
    // **MEASURED: A PACK OF ZEROS PASSES THIS CHECK**, because the comparison
    // ends before the first block's words reach main memory --- so the pack's
    // content is exercised by `disk_boot.pass`, at the controller, and by
    // nothing at machine level.  Said here rather than left to be assumed,
    // because a check that passes while testing nothing is this repository's
    // commonest failure.
    Check(pack.served_image() >= 1,
          "%ld blocks were fetched from the pack, wanting at least one at a "
          "disk address the controller posted",
          pack.served_image());
    Check(feeder.denied == 0, "%ld requests were denied; the pack covers "
          "every address this program asks for", feeder.denied);
    // Every tolerated burst has to be the spindle's region and nothing else.
    for (auto &m : burst_masks)
      Check((m.first & ~0x1F000000u) == 0,
            "%ld tolerated disagreements moved MD outside STATUS<28:24> "
            "(mask %08x); --tolerate is for the drive's rotational position "
            "and for nothing else",
            m.second, m.first);
  }

  // ============== THE PORT'S OWN CLAUSES, ASSERTED IN EITHER MODE ==========
  //
  // These are properties of the composition and not of the reference, so they
  // hold whether the run was compared against muir or ran free past it.  The
  // guards come first: a clause that never applied passed by not running.
  // ================= THE PACK SIDE'S OWN CLAUSES ==========================
  //
  // The whole reason this file exists beside `tb/cadr_band_axi_tb.cpp` is that
  // `cadr_disk_pack` is in the design here.  These say it behaved, and each
  // counts so that a zero can be read as "none happened" rather than "never
  // applied".
  Check(hp2.read_bursts > 0,
        "the pack side never read a record out of DDR: the seam is in the "
        "design but nothing crossed it");
  Check(hp2.bad == 0,
        "%ld AXI3 rules were broken on S_AXI_HP2 by the pack side", hp2.bad);
  Check(gp0.bad == 0,
        "%ld register accesses on M_AXI_GP0 went wrong", gp0.bad);
  Check(hp2.aw_handshakes == hp2.write_bursts &&
            hp2.b_responses == hp2.write_bursts,
        "%ld write bursts on HP2 against %ld address handshakes and %ld "
        "responses; one of each a burst, or a duplicate went unseen",
        hp2.write_bursts, hp2.aw_handshakes, hp2.b_responses);
  // THE CLAUSE THIS HARNESS WAS BUILT FOR.  The staging records are at
  // 0x1C80_0000 and up; the machine's own 22-bit physical space is
  // 0x1800_0000 to 0x1900_0000.  A pack-side beat inside that range is a
  // block of somebody else's memory overwritten, which is the exact shape of
  // the board's page-hash-table word.
  Check(hp2_in_main == 0,
        "%ld beats of the pack side landed inside the machine's own main "
        "memory", hp2_in_main);
  Check(hp2_outside_staging == 0,
        "%ld beats of the pack side landed outside the staging records the "
        "program pointed it at", hp2_outside_staging);
  Check(feeder.errors == 0,
        "%ld moves came back with the pack side's error bit set",
        feeder.errors);

  Check(req_rises > 0, "the machine made no memory request at all");
  Check(ar_handshakes + aw_handshakes > 0,
        "no AXI transaction went out; the port is not in the path");
  Check(words_read_back > 0,
        "no read was compared against the store: the read-lane clause is not "
        "being exercised");
  Check(answers_per_request_wrong == 0,
        "%ld requests were answered other than exactly once",
        answers_per_request_wrong);
  Check(txns_per_request_wrong == 0,
        "%ld requests issued other than exactly one transaction of their own "
        "direction", txns_per_request_wrong);
  Check(txns_outside_a_request == 0,
        "%ld AXI transactions went out with no request standing",
        txns_outside_a_request);
  Check(direction_wrong == 0,
        "%ld transactions went out in a direction the processor's own WRCYC "
        "does not name", direction_wrong);
  Check(beat_unaligned == 0,
        "%ld transactions at an address that is not a 64-bit beat",
        beat_unaligned);
  Check(bad_strobes == 0,
        "%ld writes whose strobes were not one half of a beat", bad_strobes);
  Check(strobe_half_wrong == 0,
        "%ld writes whose strobes named the half the address does not",
        strobe_half_wrong);
  Check(wdata_not_offered_twice == 0,
        "%ld beats did not carry the bridge's word in both halves",
        wdata_not_offered_twice);
  Check(read_lane_wrong == 0,
        "%ld reads came back with a word the store does not hold at the "
        "address the bridge asked for", read_lane_wrong);
  Check(neighbour_disturbed == 0,
        "%ld writes disturbed the other half of their own beat",
        neighbour_disturbed);
  Check(ar_handshakes == req_read_rises && aw_handshakes == req_write_rises,
        "%ld read and %ld write transactions against %ld read and %ld write "
        "requests", ar_handshakes, aw_handshakes, req_read_rises,
        req_write_rises);
  Check(r_handshakes == ar_handshakes && b_handshakes == aw_handshakes &&
        w_handshakes == aw_handshakes,
        "%ld read answers, %ld write answers and %ld write beats against %ld "
        "reads and %ld writes", r_handshakes, b_handshakes, w_handshakes,
        ar_handshakes, aw_handshakes);
  Check(writes_unasked == 0,
        "%ld writes went out at the port with the processor's WRCYC down and "
        "the channel idle", writes_unasked);
  Check(cycles_multi == 0,
        "%ld bus cycles carried more than one transaction (worst %ld)",
        cycles_multi, multi_worst);

  if (fails) {
    std::fprintf(stderr, "\nFAILED: %d\n", fails);
    return 1;
  }
  std::printf(
      "ok: %" PRIu64 " microcycles of a System 100 band on the WHOLE machine agree\n"
      "    with muir's rtl engine --- PC, IR, LPC, OPC, ST, LC, the A and M buses,\n"
      "    the ALU, R, OB, Q, DC, VMA, MD, -VMAOK, JCOND, NOP, PCS1, PCS0, IWRITED,\n"
      "    PROMDISABLE and -XBUS.INTR --- through `cadr_axi_master` and\n"
      "    `cadr_axi_widen` into a 64-bit AXI3 slave keyed by its own beat address,\n"
      "    with a DRIVE on the cable and a REAL pack behind the block store's seam,\n"
      "    and with the two clocks the same to the nanosecond throughout\n"
      "    %" PRIu64 " of them are past microcycle 537,857, where this trace and the\n"
      "      boot PROM's part company, so they are a program no other check runs on\n"
      "      the whole machine, with the disk controller answering out of a real\n"
      "      drive instead of the no-drive constant\n"
      "    NOT REACHED, and the header says why each is structural rather than a\n"
      "      longer run away: the machine never leaves the boot PROM here, no pack\n"
      "      block ever reaches main memory, the map is never written with an\n"
      "      asymmetric access code, and the comparison cannot pass the machine's\n"
      "      first disk transfer because muir's channel takes no time and makes no\n"
      "      bus cycle.  docs/band.md has the account.\n"
      "    AND THE PACK'S CONTENT IS NOT CHECKED: a pack of zeros passes this,\n"
      "      measured, because the comparison ends before the first block's words\n"
      "      reach main memory.  What is held is that the seam ran and the disk\n"
      "      address came from the fabric.\n",
      k, k > 537857 ? k - 537857 : 0);
  return 0;
}
