// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// THE WHOLE MACHINE ON THE BAND, WITH A REAL MEMORY AND A REAL PACK.
//
// `cadr_machine` from reset, running microcode 323 off a System 100 pack, held
// to muir's own `rtl` engine microcycle for microcycle out of
// `build/rtl_sys.golden` --- with NOTHING driven nearer than `mem_req`/
// `mem_done` and the block store's seam.  The word `MD` takes is fetched from
// a store keyed by `mem_addr`; the block a transfer moves is fetched from the
// pack file by the disk address the controller itself posts; and the disk's
// interrupt, the map's permission bits and the microcycle's whole datapath are
// the fabric's own.
//
// **THE HOLE THIS IS AIMED AT.**  Every processor check in this repository
// compares `cadr_microcycle` against muir with the bus, the memory and the
// acknowledgements supplied from muir's own columns; `machine.pass` and
// `map_boot.pass` compare the whole machine, but on MIT's boot PROM, which is
// a different program and stops before the microcode is loaded.  So the
// composed machine --- processor, bus interface, memory path, real memory,
// disk controller --- has never been asked to agree with muir while running
// the microcode it loads off its own disk.  CLAUDE.md states the gap twice,
// once as "NO CHECK HAS EVER MOVED A REAL PACK BLOCK INTO MAIN MEMORY" and
// once as "map-write-then-read-through-it across `cadr_machine` has never been
// compared to muir".
//
// ====================================================================
// HOW FAR THIS REACHES, AND WHY IT STOPS WHERE IT DOES.  MEASURED.
// ====================================================================
//
// **1,062,507 of the band's 2,800,000 microcycles agree exactly**, every
// column below, no exemption of any kind, and the fabric's clock and muir's
// the same to the nanosecond over the whole of it.  Measured at `822535c`.
// That is the boot PROM run with a DRIVE ON THE CABLE, which no other check
// does: `rtl.golden` and `rtl_sys.golden` are byte-identical only to 537,857
// and part there, so 524,650 of those microcycles are a program nothing else
// runs on the whole machine, and the disk controller answers them out of a
// real drive --- unit selection, the spindle, on-line, on-cylinder, seek and
// attention --- instead of the no-drive constant `0x2321` that CLAUDE.md says
// a wire would pass.
//
// **It stops at the machine's FIRST DISK TRANSFER, and the reason is that
// muir's channel does not exist.**  `Controller::timed` is `false` by default
// and `golden/src/rtl_sys.rs` never sets it, so `done_in` finishes every
// operation at the instant it starts; and `Controller::transfer` writes
// straight into `main: &mut [u32]` rather than over the Xbus.  The fabric's
// channel is a second Xbus master --- 256 bus cycles a page through the
// arbiter, plus 261 ticks to put each block through the store's seam a word at
// a time --- so at reference microcycle 1,062,507 the boot PROM reads the
// status register, `ch_active` and `ch_waiting` are both up, and `STATUS<0>`
// not-active reads 0 where muir reads 1.  `build/rtl_sys.golden` carries 457
// disk interrupts, 225 of them before the cold load ends: this is the program
// and not a rare event to be exempted.
//
// **THREE WAYS ROUND IT WERE BUILT AND MEASURED, AND NONE OF THEM WORKS.**
// They are kept as flags because what they print is the reason.
//
//   `--absorb N` holds the reference row and lets the fabric run until its
//     whole sample is that row again --- the obvious answer, since the machine
//     is only going round a wait loop more times.  It does not rejoin, ever,
//     and the near misses say why: `OPC` and `LPC` are the eighth and first
//     stages of the shift register of past PCs, so a machine that waited
//     longer CARRIES that, and the state it arrives in is not the reference
//     row.  A machine's history is part of its state.
//
//   `--timed` charges the drive's own seek and rotational wait, on both sides
//     --- which is the one thing that makes the two channels finish together,
//     because the fabric's 256 bus cycles fit inside the drive's own window
//     and `elapsed` counts the wait off the access time.  It works, as far as
//     it goes: two real pack blocks move into main memory and the machine does
//     not notice, and the two clocks stay within 150 ns over 1,076,016
//     microcycles.  Then the drive's block counter, `STATUS<28:24>`, reads one
//     apart, because 150 ns is enough to put the spindle on the other side of
//     a sector pulse.  **It needs a reference generated with
//     `m.disk.timed = true`, which this repository does not have**; the
//     measurements above were taken against one made in a worktree.
//
//   `--tolerate N` lets a disagreement stand for at most N microcycles in
//     LOCKSTEP, both machines executing the same microcycle and differing
//     about a value in it, which is what a spindle one region out is.  With
//     the drive timed and N = 16 it reaches 1,205,508 with nineteen bursts of
//     89 microcycles in all, every one of them confined to `STATUS<28:24>`.
//     At N = 512 it reaches 1,276,905 --- **and a burst appears that moves PC,
//     IR and VMA**, which is the exemption beginning to hide the machine
//     rather than the clock.  That is CLAUDE.md's standing hazard caught in
//     the act, and it is why the default is zero.
//
// **AND EVEN WITH A PERFECT CLOCK THIS SHAPE CANNOT REACH THE WINDOW.**  The
// band's machine reads its own microsecond clock --- Unibus `0o764120` and
// `0o764122`, the I/O board's counter --- 476 times, the first at microcycle
// 2,087,406, and the value is elapsed microseconds.  Those two addresses and
// `0o766040` are the only three Unibus addresses the whole 2,800,000
// microcycles touch, 476, 476 and 240 times.  So the divergence window this
// was built to search, 2,093,261 to 4,441,390, begins 5,855 microcycles after
// the machine has started reading a value that is a function of the instant it
// is at.  `docs/band.md` has the whole account and what would close it.
//
// ====================================================================
// WHAT IS STIMULUS, AND WHY A DISAGREEMENT MEANS THE MACHINE
// ====================================================================
//
// THE MEMORY.  A store keyed by `mem_addr`, zero where nothing has written ---
// which is what `Machine::with_memory_boards` gives muir, `main: vec![0;
// boards << 16]` --- so the comparison against muir is exact with no exemption
// anywhere.  Reads of words nothing has written are COUNTED and printed rather
// than exempted, because a store that answers zero everywhere would agree with
// muir while testing nothing, and the count is what says how much of the
// traffic is really reading back what the machine put there.  The word on
// `mem_rdata` whenever the model is NOT answering is poison, a function of the
// address, so a bridge that latched at the wrong instant takes something
// nothing should ever hold.
//
// **THE ANSWER IS PLACED WHERE muir PLACED IT**, out of the trace's own `ack`
// column, as `tb/cadr_machine_tb.cpp` and `tb/cadr_map_boot_tb.cpp` place it.
// A memory of no access time is NOT muir: `busint.rs`'s `Responder::Memory`
// goes through `MemoryBoard::request`, which has the board's own refresh in
// it, and measured over the boot PROM's parity loop its answers land 573 and
// 608 ns after the grant where a device's land 140.  Answering as fast as the
// bus allows was tried first and is what found that: it made the fabric's
// stalled microcycles 404 ns short each, 518 of them, and nothing else moved
// at all.  A memory answering at a delay of ITS OWN is
// `tb/cadr_ddr_boot_tb.cpp`'s question and is not re-asked here.
//
// The channel's own memory cycles have no column --- muir's channel makes
// none --- so they are answered as soon as they are asked, and counted
// separately.
//
// THE PACK.  A copy of the System 100 release image, opened READ-ONLY, and a
// block the machine writes is kept in memory for the run exactly as muir's
// `Unit::written` keeps it.  The header and both checkwords are computed from
// the address and the data at the move, as `disk_unit::header_of` and `Ecc`
// compute them and as CLAUDE.md's sidecar decision settled.  **The feeder is
// stimulus and never a shadow**: what it serves comes from the pack file at
// the disk address the controller posted, and an address off the pack is
// DENIED rather than invented.
//
// THE DRIVE.  One unit present, not read-only, and `drive_timed` LOW --- which
// is `Controller::timed` false, the way the reference was generated.  A drive
// whose time was charged here would be a second disagreement with the
// reference on top of the channel's.
//
// WHAT IS NOT DRIVEN AT ALL.  `device_ack` is low and never raised: the disk
// controller and the display inside the machine answer their own addresses.
// The I/O board's cables are at rest --- no key, no mouse, no serial, no
// Chaosnet --- which is what muir's `IoBoard::default()` is; the reference
// never reads the keyboard, the mouse or the status register, so none of them
// is exercised here and the check says so rather than claiming them.  The
// console's seam is idle.

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

#include "Vcadr_machine.h"
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
  for (int i = 1; i < argc; ++i) {
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
      std::printf("band: skipped --- no System 100 release\n");
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

  auto *dut = new Vcadr_machine;
  dut->clk = 0;
  dut->rst = 1;
  dut->boards = 32;              // Machine::new: MAIN_WORDS >> 16
  dut->mem_done = 0;
  dut->mem_rdata = 0;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  // One drive on the cable, writable, and its own time NOT charged:
  // `Controller::timed` is false in muir and `golden/src/rtl_sys.rs` never
  // sets it.
  dut->drive_present = 0x01;
  dut->drive_read_only = 0x00;
  dut->drive_timed = timed;
  dut->store_we = 0;
  dut->store_slot = 0;
  dut->store_addr = 0;
  dut->store_wdata = 0;
  dut->store_busy = 0;
  dut->store_busy_slot = 0;
  dut->store_deny = 0;
  dut->kbd_strobe = 0;
  dut->kbd_code = 0;
  dut->mouse_lines = 0;
  dut->ser_ready = 0;
  dut->chaos_intr = 0;
  dut->con_req = 0;
  dut->con_msyn = 0;
  dut->con_write = 0;
  dut->con_addr = 0;
  dut->con_wdata = 0;
  dut->con_ro_addr = 0;
  dut->eval();

  // ------------------------------------------------------- the pack side
  //
  // The far end of the block store's seam, as `rtl/plumbing/cadr_disk_pack.sv`
  // drives it and in its order: the slot is taken away first, its 256 data
  // words and three meta words go in one a tick, and the TAG goes in LAST ---
  // so a walk reaching the slot during the fill misses it and waits, rather
  // than reading a block half old and half new.  `store_busy` is up from one
  // tick before the first write to the tick of the last.
  constexpr int kSlots = 24;
  constexpr int kStHeader = 256, kStHck = 257, kStDck = 258, kStTag = 259;

  enum Feeder { F_IDLE, F_EVICT, F_FILL };
  Feeder feeder = F_IDLE;
  int f_slot = 0, f_step = 0;
  uint32_t f_words[kBlockWords];
  uint32_t f_hdr = 0, f_hck = 0, f_dck = 0, f_tag = 0;
  // What this testbench believes each slot holds, which is what it wrote.
  std::vector<uint32_t> slot_tag(kSlots, 0);
  std::vector<uint8_t> slot_valid(kSlots, 0), slot_dirty(kSlots, 0);
  std::vector<uint64_t> slot_used(kSlots, 0);
  std::vector<uint32_t> evict_buf(kBlockWords, 0);
  int next_slot = 0;
  long fills = 0, evictions = 0, denials = 0, deny_pending = 0;
  long fill_ticks = 0;
  uint64_t fill_started = 0;
  long longest_wait = 0;

  auto tag_of = [](unsigned unit, unsigned c, unsigned h, unsigned b) {
    return (unit & 7u) << 28 | (c & 0xFFFu) << 16 | (h & 0xFFu) << 8 | (b & 0xFFu);
  };

  // ------------------------------------------------------ the comparison
  auto take = [&]() {
    Sample s;
    std::memset(&s, 0, sizeof s);
    s.ir = dut->ir;
    s.st = dut->st; s.a = dut->a; s.m = dut->m; s.alu = dut->alu;
    s.r = dut->r; s.ob = dut->ob; s.q = dut->q;
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

  // One transaction per memory cycle: `mem_req` stands until the bridge has
  // taken the word, so the store must be touched exactly once however many
  // ticks `mem_done` is up for.
  bool served = false;
  uint32_t served_addr = 0;
  uint8_t served_write = 0;
  uint32_t held_rdata = 0;
  // The processor's cycle in flight and when muir's own interface answered it.
  bool bus_outstanding = false;
  int64_t ack_at_tick = 0;
  long mem_unkeyed = 0;     // cycles muir has no column for: the channel's

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

    // ---- the memory, answering where muir's own interface answered -----
    dut->mem_done = 0;
    // Poison while nothing is answering, and never a word of the store.
    dut->mem_rdata = Poison(dut->mem_addr ^ 0x5A5A5A5Au);
    // A read is deskewed by `XBUS_ACK_NS` and a write is not, so the model is
    // asked 60 ns before -MEMACK on a read and at it on a write, which is
    // where `Responder::Memory` put its answer.
    const bool at_muirs_instant =
        bus_outstanding &&
        static_cast<int64_t>(t) >=
            ack_at_tick - (dut->mem_write ? 0 : kXbusAckNs / kTickNs);
    if (dut->mem_req && (at_muirs_instant || !bus_outstanding)) {
      if (!bus_outstanding) ++mem_unkeyed;
      if (!served || served_addr != dut->mem_addr || served_write != dut->mem_write) {
        served = true;
        served_addr = dut->mem_addr;
        served_write = dut->mem_write;
        const uint32_t a = dut->mem_addr;
        if ((a & 3u) != 0) ++mem_misaligned;
        const bool in_main = a >= kMainBase && a < kMainBase + 4u * kMainWords;
        const size_t w = (a - kMainBase) >> 2;
        if (dut->mem_write) {
          ++mem_writes;
          if (in_main) { main_mem[w] = dut->mem_wdata; touched[w] = 1; }
          else { elsewhere[a] = dut->mem_wdata; ++mem_outside; }
        } else {
          ++mem_reads;
          if (in_main) {
            held_rdata = main_mem[w];
            if (!touched[w]) ++mem_untouched_reads;
          } else {
            ++mem_outside;
            auto it = elsewhere.find(a);
            held_rdata = (it != elsewhere.end()) ? it->second : 0u;
          }
        }
      }
      if (!dut->mem_write) dut->mem_rdata = held_rdata;
      dut->mem_done = 1;
    }
    if (!dut->mem_req) served = false;

    // ---- the Xbus seam: nothing out there answers ---------------------
    dut->device_rdata = Poison(static_cast<uint32_t>(dut->phys) << 2);

    // ---- the pack side -------------------------------------------------
    dut->store_we = 0;
    dut->store_deny = 0;
    // The interlock, read a tick behind as `cadr_disk_pack.sv` reads it.
    const bool walk_holds = dut->ch_active && !dut->ch_waiting;
    if (feeder == F_IDLE) {
      dut->store_busy = 0;
      if (dut->req_valid) {
        if (!fill_started) fill_started = t;
        const uint32_t tag = dut->req_tag;
        const uint32_t unit = (tag >> 28) & 7u;
        const uint32_t c = (tag >> 16) & 0xFFFu;
        const uint32_t h = (tag >> 8) & 0xFFu;
        const uint32_t b = tag & 0xFFu;
        if (unit != 0 || !pack.OnPack(c, h, b)) {
          // Linux cannot serve it.  A one-tick pulse, and only while the walk
          // is standing in `C_LOOK`: delivered anywhere else it drops the
          // request without ending the transfer, and the walk hangs.
          if (dut->ch_waiting) { dut->store_deny = 1; ++denials; fill_started = 0; }
        } else {
          // Any slot but the one the walk is on.  A dirty slot is written back
          // to the pack first --- the store is a cache, and a block the
          // machine wrote lives only in the slot until somebody takes it out.
          int pick = -1;
          for (int i = 0; i < kSlots && pick < 0; ++i) {
            const int s = (next_slot + i) % kSlots;
            if (walk_holds && s == dut->ch_slot) continue;
            if (!slot_valid[s] || !slot_dirty[s]) pick = s;
          }
          if (pick < 0) {
            uint64_t oldest = UINT64_MAX;
            for (int s = 0; s < kSlots; ++s) {
              if (walk_holds && s == dut->ch_slot) continue;
              if (slot_used[s] < oldest) { oldest = slot_used[s]; pick = s; }
            }
          }
          if (pick >= 0) {
            f_slot = pick;
            next_slot = (pick + 1) % kSlots;
            f_tag = tag & 0x7FFFFFFFu;
            pack.Read(c, h, b, f_words);
            f_hdr = HeaderOf(c, h, b);
            const uint8_t hb[4] = {
                static_cast<uint8_t>(f_hdr), static_cast<uint8_t>(f_hdr >> 8),
                static_cast<uint8_t>(f_hdr >> 16), static_cast<uint8_t>(f_hdr >> 24)};
            f_hck = Ecc::over_bytes(hb, 4);
            f_dck = Ecc::over_words(f_words, kBlockWords);
            f_step = 0;
            if (slot_valid[f_slot] && slot_dirty[f_slot]) {
              feeder = F_EVICT;
              ++evictions;
            } else {
              feeder = F_FILL;
            }
            dut->store_busy = 1;
            dut->store_busy_slot = f_slot;
          }
        }
      }
    } else if (feeder == F_EVICT) {
      // The slot read out a word a tick, `store_rdata` two ticks behind the
      // address it was asked at.  Nothing is written, so the slot and its tag
      // stand while this runs.
      dut->store_busy = 1;
      dut->store_busy_slot = f_slot;
      dut->store_slot = f_slot;
      if (f_step < kBlockWords) dut->store_addr = f_step;
      if (f_step >= 2 && f_step - 2 < kBlockWords) evict_buf[f_step - 2] = dut->store_rdata;
      ++f_step;
      if (f_step >= kBlockWords + 2) {
        const uint32_t tag = slot_tag[f_slot];
        pack.Write((tag >> 16) & 0xFFFu, (tag >> 8) & 0xFFu, tag & 0xFFu,
                   evict_buf.data());
        slot_dirty[f_slot] = 0;
        feeder = F_FILL;
        f_step = 0;
      }
    } else {   // F_FILL
      dut->store_busy = 1;
      dut->store_busy_slot = f_slot;
      dut->store_slot = f_slot;
      dut->store_we = 1;
      if (f_step == 0) {
        dut->store_addr = kStTag;
        dut->store_wdata = 0x80000000u;        // take the block away first
        slot_valid[f_slot] = 0;
        slot_dirty[f_slot] = 0;
      } else if (f_step <= kBlockWords) {
        dut->store_addr = f_step - 1;
        dut->store_wdata = f_words[f_step - 1];
      } else if (f_step == kBlockWords + 1) {
        dut->store_addr = kStHeader; dut->store_wdata = f_hdr;
      } else if (f_step == kBlockWords + 2) {
        dut->store_addr = kStHck; dut->store_wdata = f_hck;
      } else if (f_step == kBlockWords + 3) {
        dut->store_addr = kStDck; dut->store_wdata = f_dck;
      } else {
        dut->store_addr = kStTag; dut->store_wdata = f_tag;   // and the tag LAST
        slot_tag[f_slot] = f_tag;
        slot_valid[f_slot] = 1;
        slot_used[f_slot] = t;
      }
      ++f_step;
      if (f_step > kBlockWords + 4) {
        feeder = F_IDLE;
        ++fills;
        if (fill_started) {
          const long waited = static_cast<long>(t - fill_started);
          fill_ticks += waited;
          if (waited > longest_wait) longest_wait = waited;
          fill_started = 0;
        }
      }
    }

    dut->clk = 1;
    dut->eval();

    if (bus_outstanding && !dut->mem_req && !dut->dev_rq &&
        static_cast<int64_t>(t) > ack_at_tick)
      bus_outstanding = false;

    // A transfer has written a slot: the pack holds the block only once this
    // side has taken it out again.
    if (dut->ch_wrote) slot_dirty[dut->ch_slot] = 1;
    if (dut->ch_hit) slot_used[dut->ch_slot] = t;

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
        if (observing) continue;
        ++k;
        if (k < total_rows && !read_next(cur)) {
          std::fprintf(stderr, "FAIL: %s: ran out of rows at %" PRIu64 " of %"
                       PRIu64 "\n", trace_path, k, total_rows);
          ++fails;
          break;
        }
      }

    }

    dut->clk = 0;
    dut->eval();
    prev = take();
  }
  if (!stopped_because && t >= max_ticks) stopped_because = "the tick budget ran out";

  dut->final();
  delete dut;
  std::fclose(f);

  fails += bad;

  std::printf(
      "band: %" PRIu64 " of %" PRIu64 " reference microcycles compared, "
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
      evictions, pack.distinct_written(), fills, denials,
      fill_ticks, fills, longest_wait);
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
    Check(denials == 0, "%ld requests were denied; the pack covers every "
          "address this program asks for", denials);
    // Every tolerated burst has to be the spindle's region and nothing else.
    for (auto &m : burst_masks)
      Check((m.first & ~0x1F000000u) == 0,
            "%ld tolerated disagreements moved MD outside STATUS<28:24> "
            "(mask %08x); --tolerate is for the drive's rotational position "
            "and for nothing else",
            m.second, m.first);
  }

  if (fails) {
    std::fprintf(stderr, "\nFAILED: %d\n", fails);
    return 1;
  }
  std::printf(
      "ok: %" PRIu64 " microcycles of a System 100 band on the WHOLE machine agree\n"
      "    with muir's rtl engine --- PC, IR, LPC, OPC, ST, LC, the A and M buses,\n"
      "    the ALU, R, OB, Q, DC, VMA, MD, -VMAOK, JCOND, NOP, PCS1, PCS0, IWRITED,\n"
      "    PROMDISABLE and -XBUS.INTR --- with a REAL memory keyed by mem_addr, a\n"
      "    DRIVE on the cable and a REAL pack behind the block store's seam, and\n"
      "    with the two clocks the same to the nanosecond throughout\n"
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
