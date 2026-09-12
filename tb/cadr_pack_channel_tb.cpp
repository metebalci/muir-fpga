// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A BLOCK OF A PACK OUT OF DDR, THROUGH THE PACK SIDE, THROUGH THE CHANNEL,
// THROUGH THE ADAPTER AND THE WIDENING, INTO MAIN MEMORY --- AND OUT AGAIN
// WORD FOR WORD.
//
// **THE HOLE THIS IS AIMED AT.**  `axi_channel.pass` runs MIT's boot PROM with
// a drive on the cable and a pack behind the block store's seam, and its
// strongest clause is that a page the channel filled decodes as a block the
// feeder served.  But its feeder IS a testbench: it writes 259 words into a
// slot a word at a time.  `rtl/plumbing/cadr_disk_pack.sv` --- the module that
// does that on the board, the `S_AXI_HP2` master that fetches the record out
// of DDR, and the `M_AXI_GP0` register face the `cadr-disk-packs` program
// writes --- has NEVER been instantiated in a whole-machine check anywhere in
// this tree.  `disk_pack.pass` holds it to properties on a directed stimulus
// with no machine behind it.
//
// So this is `tb/cadr_axi_channel_tb.cpp` with the pack side IN THE DESIGN.
// The DUT is `tb/cadr_pack_axi_harness.sv`; the feeder is replaced by
// `tb/cadr_pack_linux.h`'s Linux, which puts the record into DDR at
// `pack_feeder.h`'s own staging address and writes ADDR, TAG, SLOT and CTL
// over GP0; and the record crosses into the store as nine AXI3 bursts rather
// than as 259 testbench assignments.  **Every clause of the original survives
// unchanged**, because the property they state is about the words and not
// about who moved them --- and that is the point: the same eight clauses now
// span one more module and two more ports.
//
// **THE PACK IS STILL SYNTHETIC, POISON INJECTIVE IN THE DISK ADDRESS AND
// DECODABLE.**  Word `i` of block `l` is `0xA8000000 | l << 8 | i`.  So a page
// of main memory is READ BACK AND DECODED without the testbench being told
// where the CCW walk put it, and now without its being told where the pack
// side put it either.  The record travels: testbench -> DDR -> HP2 -> the
// block store -> the channel -> HP0 -> DDR, and the clause is that what comes
// out the far end decodes as what went in.
//
// **THE TWO PORTS SHARE ONE MEMORY**, as they do on the board, where HP0 and
// HP2 are two doors into one DRAM.  Two clauses live on that: a pack-side beat
// inside the machine's own address range, and a pack-side beat outside the
// staging records.  Both are zero on a correct run and both are the shape of
// CLAUDE.md's board fault --- a write nobody asked for, landing on somebody
// else's word.
//
// **WHAT THIS CANNOT DO**, said at the top for `tb/cadr_axi_channel_tb.cpp`'s
// reason.  It is not compared against muir: there is no reference for a fabric
// channel or for an AXI master, so this is held to properties.  And the
// board's own event is one in a hundred and seventy-six million microcycles
// while this is a few hundred thousand; green here means these properties hold
// for the program we can run.  `make pack-band` is the same composition run on
// the band, and it is not a check.


#include <cstdarg>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <unordered_map>
#include <vector>

#include "Vcadr_pack_axi_harness.h"
#include "cadr_pack_linux.h"
#include "verilated.h"

namespace {

// `cadr_ddr_map::MAIN_BASE`, and enough of it for everything 32 memory boards
// can reach that this program touches.
constexpr uint32_t kMainBase = 0x18000000u;
constexpr size_t kMainWords = 4u << 20;      // 16 MB
constexpr int kPageWords = 256;

// `disk_unit::Geometry::T300`, which is what a CADR has on its cable.
constexpr uint32_t kCylinders = 815;
constexpr uint32_t kHeads = 19;
constexpr uint32_t kBlocksPerTrack = 17;
constexpr int kBlockWords = 256;

// `Ecc`, the controller's error-correcting register as DCECC wires it: thirty
// -two stages, taps 31, 29, 20, 10 and 8, a bit at a time low-order first.
constexpr uint32_t kEccPoly = 0xA0100500u;

// How long to run before giving up on the machine ever reaching its disk.
// The boot PROM's first main-memory cycle is microcycle 536,303 and its first
// disk poll 537,848, which is about 24,000,000 ticks; the cold boot's first
// transfer follows.  The run stops as soon as `kWantTransfers` have finished,
// so this is a ceiling and not the length.
constexpr long kTickCeiling = 60000000L;
// HOW MUCH OF THE CHANNEL THIS CAN EXERCISE, MEASURED AND NOT HOPED FOR.
// The boot PROM asks the drive for three blocks --- the label and the band ---
// and exactly ONE of them is a 256-word page moved into main memory; the
// others are a refill the store already held and a transfer that moves no
// memory word.  Then the PROM reads the label, finds poison where `LABL`
// should be, and stops: at 60,000,000 ticks the machine stands at PC 0o26
// with PROMDISABLE still clear, and no further transfer ever happens.
//
// **THAT IS THE PRICE OF A SYNTHETIC PACK AND IT IS PAID DELIBERATELY.**  A
// pack with a real label would carry a real microcode band or none, and a
// machine that disables its PROM and runs poison as microinstructions is not
// a stimulus anybody can reason about.  `make band-axi` is the same
// composition on a REAL pack, where the machine boots to a painted screen ---
// and it needs the System 100 release, which is what keeps it out of `make
// check` and out of `mutations/run.py`.
constexpr long kWantTransfers = 3;
// And the clause has to have applied to at least this many pages, or the
// check passed by not running.  One 256-word page, decoded word for word.
constexpr long kWantPages = 1;

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

// THE PACK'S OWN WORD, AND IT IS DECODABLE ON PURPOSE.  Bits 31:26 are a
// marker, bits 25:8 the block's LBA and bits 7:0 its place in the block.  The
// marker is `0b101010`, which no address, no zero and no all-ones carries, so
// a word found in main memory either IS a pack word and says which one, or is
// not one at all.  That is what lets clause 5 read a page back without being
// told where the CCW walk put it.
constexpr uint32_t kPackMark = 0xA8000000u;
constexpr uint32_t kPackMarkMask = 0xFC000000u;
uint32_t PackWord(uint32_t lba, int i) {
  return kPackMark | ((lba & 0x3FFFFu) << 8) | static_cast<uint32_t>(i & 0xFF);
}
bool IsPackWord(uint32_t w) { return (w & kPackMarkMask) == kPackMark; }
uint32_t PackLba(uint32_t w) { return (w >> 8) & 0x3FFFFu; }
int PackIndex(uint32_t w) { return static_cast<int>(w & 0xFFu); }

// A word for main memory that is not zero, not any other word's, not the
// address, and NOT a pack word --- the marker is what keeps the two apart.
uint32_t Poison(size_t word) {
  uint32_t p = (0x9E3779B9u * static_cast<uint32_t>(word + 1u)) ^ 0xA5A5A5A5u;
  if ((p & kPackMarkMask) == kPackMark) p ^= 0x04000000u;
  if (p == 0) p = 0x5EEDFACEu;
  return p;
}

// A small deterministic sequence for the slave's handshake delays.
uint32_t Next(uint32_t &s) {
  s = s * 1103515245u + 12345u;
  return (s >> 16) & 0x7FFFu;
}

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

uint32_t Lba(uint32_t c, uint32_t h, uint32_t b) {
  return c * (kHeads * kBlocksPerTrack) + h * kBlocksPerTrack + b;
}
bool OnPack(uint32_t c, uint32_t h, uint32_t b) {
  return c < kCylinders && h < kHeads && b < kBlocksPerTrack;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  // ---------------------------------------------------------- the memory
  std::vector<uint32_t> main_mem(kMainWords);
  std::vector<uint8_t> touched(kMainWords, 0u);
  for (size_t i = 0; i < kMainWords; ++i) main_mem[i] = Poison(i);
  std::unordered_map<uint32_t, uint32_t> elsewhere;   // the display's region

  auto *dut = new Vcadr_pack_axi_harness;
  dut->clk = 0;
  dut->rst = 1;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  // THE DRIVE AND THE SEAM ARE NOT DRIVEN HERE.  `cadr_disk_pack` drives all
  // eleven of them now --- `drive_present` included, off the DRIVE register
  // Linux writes --- and they are outputs of the harness.  CLAUDE.md's `md`
  // trap says a port that stops being stimulus must stop being written, so
  // the lines are gone rather than left to be harmlessly overwritten.
  dut->con_ro_addr = 0x3FFFF;
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
  // LINUX AND THE DDR BEHIND HP2.  `tb/cadr_pack_linux.h` is the AXI3 slave
  // the pack side masters, a single-beat GP0 master, and `cadr-disk-packs`'s
  // own loop as a state machine over register accesses.  What this testbench
  // knows is only what it SERVED --- the block it put into a staging record
  // --- and clause 5 requires a page of main memory to decode to one of those
  // on its own.
  constexpr int kSlots = pack_linux::kSlots;

  pack_linux::Hp2Slave<Vcadr_pack_axi_harness> hp2;
  pack_linux::Gp0Linux<Vcadr_pack_axi_harness> gp0;
  pack_linux::Feeder<Vcadr_pack_axi_harness> feeder;

  long seam_bad = 0, seam_shown = 0;
  auto seam_fail = [&](const char *what) {
    ++seam_bad;
    if (seam_shown++ < 20) {
      std::printf("PACK SEAM: %s\n", what);
      std::fflush(stdout);
    }
  };
  hp2.complain = seam_fail;
  gp0.complain = seam_fail;

  std::map<uint32_t, std::vector<uint32_t>> written_back;
  std::set<uint32_t> served_lbas;
  std::set<uint32_t> served_this_transfer;

  // The staging records, and the two clauses that live on the memory being
  // shared with the machine's own.
  long hp2_in_main = 0, hp2_outside_staging = 0;
  constexpr uint32_t kStagingTop = pack_linux::kSpareBase + 0x20000u;
  std::unordered_map<uint32_t, uint32_t> staging;

  auto in_main = [](uint32_t a2) {
    return a2 >= kMainBase && a2 + 7u < kMainBase + 4ull * kMainWords;
  };
  hp2.rd = [&](uint32_t a2) -> uint64_t {
    if (in_main(a2)) ++hp2_in_main;
    if (a2 < pack_linux::kSpareBase || a2 >= kStagingTop) ++hp2_outside_staging;
    if (in_main(a2)) {
      const size_t w = (a2 - kMainBase) >> 2;
      return (static_cast<uint64_t>(main_mem[w + 1]) << 32) | main_mem[w];
    }
    auto it0 = staging.find(a2);
    auto it1 = staging.find(a2 + 4u);
    const uint32_t lo = (it0 != staging.end()) ? it0->second : Poison(a2 >> 2);
    const uint32_t hi = (it1 != staging.end()) ? it1->second
                                               : Poison((a2 + 4u) >> 2);
    return (static_cast<uint64_t>(hi) << 32) | lo;
  };
  hp2.wr = [&](uint32_t a2, uint64_t v, unsigned strb) {
    if (in_main(a2)) ++hp2_in_main;
    if (a2 < pack_linux::kSpareBase || a2 >= kStagingTop) ++hp2_outside_staging;
    for (int half = 0; half < 2; ++half) {
      const unsigned m = (strb >> (4 * half)) & 0xFu;
      if (!m) continue;
      const uint32_t at = a2 + 4u * half;
      uint32_t was = 0;
      if (in_main(at)) {
        was = main_mem[(at - kMainBase) >> 2];
      } else {
        auto it = staging.find(at);
        was = (it != staging.end()) ? it->second : Poison(at >> 2);
      }
      uint32_t now = static_cast<uint32_t>(v >> (32 * half));
      for (int by = 0; by < 4; ++by)
        if (!((m >> by) & 1u))
          now = (now & ~(0xFFu << (8 * by))) | (was & (0xFFu << (8 * by)));
      if (in_main(at)) {
        const size_t w = (at - kMainBase) >> 2;
        main_mem[w] = now;
        touched[w] = 1;
      } else {
        staging[at] = now;
      }
    }
  };

  feeder.gp0 = &gp0;
  feeder.present = 0x01;
  feeder.read_only = 0x00;
  feeder.timed = false;
  feeder.read_block = [&](unsigned unit, unsigned c, unsigned h, unsigned b,
                          uint32_t *out) {
    if (unit != 0 || !OnPack(c, h, b)) return false;
    const uint32_t lba = Lba(c, h, b);
    auto it = written_back.find(lba);
    if (it != written_back.end())
      std::memcpy(out, it->second.data(), kBlockWords * 4);
    else
      for (int i = 0; i < kBlockWords; ++i) out[i] = PackWord(lba, i);
    served_lbas.insert(lba);
    served_this_transfer.insert(lba);
    return true;
  };
  feeder.write_block = [&](unsigned, unsigned c, unsigned h, unsigned b,
                           const uint32_t *w) {
    written_back[Lba(c, h, b)].assign(w, w + kBlockWords);
  };
  feeder.header_of = [](unsigned c, unsigned h, unsigned b) {
    return HeaderOf(c, h, b);
  };
  feeder.ecc_bytes = [](const uint8_t *p, int n) { return Ecc::over_bytes(p, n); };
  feeder.ecc_words = [](const uint32_t *p, int n) { return Ecc::over_words(p, n); };
  feeder.poke = [&](uint32_t at, uint32_t w) {
    if (in_main(at)) {
      const size_t wd = (at - kMainBase) >> 2;
      main_mem[wd] = w;
      touched[wd] = 1;
    } else {
      staging[at] = w;
    }
  };
  feeder.peek = [&](uint32_t at) -> uint32_t {
    if (in_main(at)) return main_mem[(at - kMainBase) >> 2];
    auto it = staging.find(at);
    return (it != staging.end()) ? it->second : Poison(at >> 2);
  };

  hp2.reset(dut);
  gp0.reset(dut);
  dut->eval();


  // ------------------------------------------------------- the AXI3 slave
  uint32_t seed = 0x5A5A1234u;
  bool aw_taken = false, w_taken = false, ar_taken = false, committed = false;
  uint32_t aw_addr = 0, ar_addr = 0, w_strb = 0;
  uint64_t w_data = 0;
  int aw_delay = 0, w_delay = 0, ar_delay = 0;
  int b_wait = -1, r_wait = -1;

  // The request window at the bridge's own port.
  bool in_request = false, req_last = false;
  int req_write = 0;
  uint32_t req_addr = 0, req_wdata = 0;
  long req_aw = 0, req_ar = 0, req_done = 0;
  long req_rises = 0, req_read_rises = 0, req_write_rises = 0;
  long aw_handshakes = 0, ar_handshakes = 0, w_handshakes = 0;
  long b_handshakes = 0, r_handshakes = 0;

  // The clauses, each counted so that a zero can be read.
  long answers_per_request_wrong = 0, txns_per_request_wrong = 0;
  long txns_outside_a_request = 0, direction_wrong = 0;
  long beat_unaligned = 0, bad_strobes = 0, strobe_half_wrong = 0;
  long wdata_not_offered_twice = 0, read_lane_wrong = 0;
  long neighbour_disturbed = 0, writes_unasked = 0;
  long non_memory_asked = 0;
  long words_read_back = 0, decode_applied = 0, decode_skipped = 0;
  long pages_checked = 0, pages_wrong = 0, pages_partial = 0;
  long mem_outside = 0, mem_misaligned = 0;
  long shown = 0;

  // The processor's own bus cycle, the audit's anchor.
  bool in_cycle = false;
  int cyc_device = 0, cyc_unibus = 0, cyc_nxm = 0, cyc_write = 0;
  int cyc_timed_out = 0;
  long cyc_own_reqs = 0;
  long memory_cycles_unasked = 0, memory_cycles_checked = 0;
  uint32_t cyc_phys = 0;
  long cycles = 0, mem_cycles = 0, dev_cycles = 0, ub_cycles = 0, nxm_cycles = 0;
  int mbusy_last = 0;

  // The channel's transfers, and what each of them wrote.
  bool ch_was = false;
  long transfers = 0, ch_up_at = 0;
  std::map<size_t, int> page_writes;    // page -> words written this transfer

  uint64_t micro = 0;
  long t = 0;
  const char *stopped = "the tick ceiling ran out";

  auto say = [&](const char *what) {
    if (shown++ < 40) {
      std::printf("CLAUSE BROKEN: %s\n"
                  "    microcycle %" PRIu64 " tick %ld  PC %o  OPC %o\n"
                  "    mem_req %d write %d addr %08x wdata %08x  phys %o\n"
                  "    wrcyc %d dev_write %d ch_active %d ch_waiting %d\n",
                  what, micro, t, dut->pc, dut->opc, dut->mem_req,
                  dut->mem_write, dut->mem_addr, dut->mem_wdata,
                  static_cast<unsigned>(dut->phys), dut->wrcyc,
                  dut->dev_write, dut->ch_active, dut->ch_waiting);
      std::fflush(stdout);
    }
  };

  auto store_word = [&](uint32_t a) -> uint32_t {
    if (a >= kMainBase && a < kMainBase + 4ull * kMainWords)
      return main_mem[(a - kMainBase) >> 2];
    auto it = elsewhere.find(a);
    return (it != elsewhere.end()) ? it->second : 0u;
  };

  for (; t < kTickCeiling; ++t) {
    dut->rst = (t < 8);

    // ----------------------------------------------- the slave's own side
    if (!dut->rst) {
      dut->hp0_awready = dut->hp0_awvalid && !aw_taken && aw_delay == 0;
      if (dut->hp0_awvalid && !aw_taken && aw_delay > 0) --aw_delay;
      dut->hp0_wready = dut->hp0_wvalid && !w_taken && w_delay == 0;
      if (dut->hp0_wvalid && !w_taken && w_delay > 0) --w_delay;
      dut->hp0_arready = dut->hp0_arvalid && !ar_taken && ar_delay == 0;
      if (dut->hp0_arvalid && !ar_taken && ar_delay > 0) --ar_delay;
    } else {
      dut->hp0_awready = dut->hp0_wready = dut->hp0_arready = 0;
      dut->hp0_bvalid = dut->hp0_rvalid = 0;
      dut->hp0_rlast = 0;
    }

    // ---------------------------------------------- the Xbus seam: nothing
    dut->device_rdata = 0;

    // ------------------------------------------------------- the pack side
    //
    // The program runs BEFORE the two faces are driven, so an access it starts
    // this tick is on the bus this tick.
    if (!dut->rst) {
      feeder.tick(static_cast<uint64_t>(t), dut->req_valid, dut->req_tag,
                  dut->ch_waiting, dut->ch_active && !dut->ch_waiting,
                  dut->ch_slot);
      gp0.drive(dut);
      hp2.drive(dut);
    } else {
      hp2.reset(dut);
      gp0.reset(dut);
    }


    // WHAT THE EDGE WILL SEE, SAMPLED BEFORE IT.
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
    const int s_req = dut->mem_req, s_req_write = dut->mem_write;
    const uint32_t s_req_addr = dut->mem_addr, s_req_wdata = dut->mem_wdata;

    hp2.sample(dut);
    gp0.sample(dut);

    dut->clk = 1;
    dut->eval();

    if (!dut->rst) {
      hp2.after_edge(dut);
      gp0.after_edge(dut);
    }

    if (!dut->rst) {
      // ------------------------------------- the processor's own bus cycle
      const int mbusy = dut->mbusy_o;
      if (mbusy && !mbusy_last) {
        cyc_write = dut->wrcyc;
        cyc_device = dut->device;
        cyc_unibus = dut->unibus;
        cyc_nxm = dut->nxm;
        cyc_phys = dut->phys;
        cyc_timed_out = 0;
        cyc_own_reqs = 0;
        in_cycle = true;
        ++cycles;
        if (cyc_device) ++dev_cycles;
        else if (cyc_unibus) ++ub_cycles;
        else if (cyc_nxm) ++nxm_cycles;
        else ++mem_cycles;
      }
      if (!mbusy && mbusy_last) {
        // CLAUSE 8.  A PROCESSOR BUS CYCLE THE DECODE CALLED MAIN MEMORY MUST
        // ASK THE PORT FOR ITS OWN ADDRESS.
        //
        // **WHY IT IS HERE, AND WHAT IT DOES NOT DO --- MEASURED, BECAUSE IT
        // WAS WRITTEN TO CATCH SOMETHING AND DOES NOT.**  Every clause above
        // counts or inspects TRANSACTIONS, so any fault that answers a
        // processor cycle without a transaction is invisible to all of them.
        // `cadr_memory_path.sv` leaves the bus idle for one tick at every
        // change of owner, and its header says what happens without that: the
        // bridge's `done` flop and `rdata` register, kept for the channel's
        // finished cycle, answer the processor's next read "in no time" with
        // the word that slave last had.  No `mem_req`, no transaction, nothing
        // above sees it.  This clause is that gap closed: a main-memory cycle
        // that finished having asked the port for nothing.
        //
        // **AND IT DOES NOT CATCH THE MUTATION THAT PROMPTED IT.**  Deleting
        // the idle tick --- `bus_rq = ch_own ? ch_req : cpu_rq` --- gives
        // exactly 517 main-memory cycles and exactly 0 unasked, the same two
        // figures as the unmutated design, because this program never hands
        // the bus over with the other master's request already standing: the
        // boot PROM's 512 memory cycles all run before the first transfer, and
        // during a transfer it polls the disk's registers rather than memory.
        // The mutation is unreached here rather than equivalent: `memory_path`
        // catches it, its configuration B streaming the channel beside the
        // processor on purpose, while `bus_audit`, `ddr_boot`, `machine`,
        // `md_compose`, `probe`, `tv` and `unibus` all miss it as this does.
        // Said here so that nobody writes this clause a second time expecting
        // it to catch that.
        //
        // The address is compared and not merely counted, because a request
        // standing inside this cycle may be the CHANNEL'S: the arbiter is per
        // word and `ch_own` is not a port of `cadr_machine`.  `phys` is the
        // processor's own physical word address, upstream of everything under
        // test, and `cadr_ddr_map::main_byte_address` is the arithmetic.
        //
        // A cycle that TIMED OUT is exempt and counted: nothing answered it,
        // so there is nothing to have asked twice.
        if (in_cycle && !cyc_device && !cyc_unibus && !cyc_nxm) {
          ++memory_cycles_checked;
          if (!cyc_timed_out && cyc_own_reqs == 0) {
            ++memory_cycles_unasked;
            say("a main-memory bus cycle finished without asking the port for "
                "its own address");
          }
        }
        in_cycle = false;
      }
      mbusy_last = mbusy;
      if (in_cycle && dut->timed_out) cyc_timed_out = 1;

      // ---------------------------------------------- the request window
      if (s_req && !req_last) {
        ++req_rises;
        if (s_req_write) ++req_write_rises; else ++req_read_rises;
        in_request = true;
        req_write = s_req_write;
        req_addr = s_req_addr;
        req_wdata = s_req_wdata;
        req_aw = req_ar = req_done = 0;
        if ((s_req_addr & 3u) != 0) ++mem_misaligned;
        if (in_cycle &&
            s_req_addr == kMainBase + (static_cast<uint32_t>(cyc_phys) << 2))
          ++cyc_own_reqs;
        // CLAUSES 6 AND 7, both of which are the PROCESSOR'S and neither of
        // which can be attributed while a transfer is in flight: `ch_own` is
        // not a port of `cadr_machine`, so a request arriving during a
        // transfer may be either master's.  Applied where they are exact, and
        // the requests they skipped are counted.
        if (!dut->ch_active) {
          ++decode_applied;
          if ((s_req_write != 0) != (dut->wrcyc != 0)) {
            ++direction_wrong;
            say("the port asks for a direction WRCYC does not name");
          }
          if (in_cycle && (cyc_device || cyc_unibus || cyc_nxm)) {
            ++non_memory_asked;
            say("a cycle the decode did not call main memory reached the port");
          }
        } else {
          ++decode_skipped;
        }
      }
      if (!s_req && req_last && in_request) {
        if (req_done != 1) {
          ++answers_per_request_wrong;
          say("a request was answered other than exactly once");
        }
        if (req_aw != (req_write ? 1 : 0) || req_ar != (req_write ? 0 : 1)) {
          ++txns_per_request_wrong;
          say("a request issued other than exactly one transaction of its own "
              "direction");
        }
        // CLAUSE 4.
        if (!req_write) {
          ++words_read_back;
          if (dut->mem_rdata != store_word(req_addr)) {
            ++read_lane_wrong;
            say("the word read back is not the word the store holds at the "
                "address the bridge asked for");
          }
        }
        in_request = false;
      }
      req_last = s_req != 0;

      // ------------------------------------------------------ the handshakes
      if (s_awvalid && s_awready) {
        ++aw_handshakes;
        aw_taken = true;
        aw_addr = s_awaddr;
        committed = false;
        ++req_aw;
        if (!in_request) {
          ++txns_outside_a_request;
          say("a write went out with no request standing at the port");
        }
        if ((s_awaddr & 7u) != 0) { ++beat_unaligned; say("a write address is "
                                                          "not a 64-bit beat"); }
        // CLAUSE 6.
        if (!dut->dev_write && !dut->ch_active) {
          ++writes_unasked;
          say("a write went out with the processor's WRCYC down and the "
              "channel idle");
        }
      }
      if (s_wvalid && s_wready) {
        ++w_handshakes;
        w_taken = true;
        w_data = s_wdata;
        w_strb = s_wstrb;
        // CLAUSE 2.
        if (s_wdata != ((static_cast<uint64_t>(req_wdata) << 32) | req_wdata)) {
          ++wdata_not_offered_twice;
          say("the beat does not carry the bridge's word in both halves");
        }
        if (s_wstrb != 0x0Fu && s_wstrb != 0xF0u) {
          ++bad_strobes;
          say("the write strobes are not one half of a beat");
        } else if (s_wstrb != (((req_addr >> 2) & 1u) ? 0xF0u : 0x0Fu)) {
          ++strobe_half_wrong;
          say("the write strobes name the half the address does not");
        }
      }
      if (aw_taken && w_taken && !committed) {
        committed = true;
        const bool in_main = aw_addr >= kMainBase &&
                             aw_addr + 7u < kMainBase + 4ull * kMainWords;
        if (!in_main) {
          ++mem_outside;
          if (w_strb & 0x0Fu) elsewhere[aw_addr] = static_cast<uint32_t>(w_data);
          if (w_strb & 0xF0u)
            elsewhere[aw_addr + 4u] = static_cast<uint32_t>(w_data >> 32);
        } else {
          const size_t w0 = (aw_addr - kMainBase) >> 2;
          const uint32_t was_lo = main_mem[w0], was_hi = main_mem[w0 + 1];
          uint64_t beat = (static_cast<uint64_t>(was_hi) << 32) | was_lo;
          for (int b = 0; b < 8; ++b)
            if (w_strb & (1u << b)) {
              const uint64_t msk = 0xFFULL << (8 * b);
              beat = (beat & ~msk) | (w_data & msk);
            }
          const uint32_t now_lo = static_cast<uint32_t>(beat);
          const uint32_t now_hi = static_cast<uint32_t>(beat >> 32);
          // CLAUSE 3, held by DATA and not by the strobe pattern alone.
          const bool hi_half = ((req_addr >> 2) & 1u) != 0;
          if (hi_half ? (now_lo != was_lo) : (now_hi != was_hi)) {
            ++neighbour_disturbed;
            say("a write disturbed the other half of its beat");
          }
          main_mem[w0] = now_lo;
          main_mem[w0 + 1] = now_hi;
          if (w_strb & 0x0Fu) touched[w0] = 1;
          if (w_strb & 0xF0u) touched[w0 + 1] = 1;
          // Which page took a word, for clause 5.  The word is the one the
          // strobes named, which is the beat's low half or its high half.
          const size_t hit = hi_half ? (w0 + 1) : w0;
          if (dut->ch_active) ++page_writes[hit / kPageWords];
        }
      }
      if (s_arvalid && s_arready) {
        ++ar_handshakes;
        ar_taken = true;
        ar_addr = s_araddr;
        ++req_ar;
        if (!in_request) {
          ++txns_outside_a_request;
          say("a read went out with no request standing at the port");
        }
        if ((s_araddr & 7u) != 0) { ++beat_unaligned; say("a read address is "
                                                          "not a 64-bit beat"); }
      }
      if (s_bvalid && s_bready) {
        ++b_handshakes;
        ++req_done;
        dut->hp0_bvalid = 0;
        b_wait = -1;
        aw_taken = w_taken = false;
        aw_delay = static_cast<int>(Next(seed) % 5);
        w_delay = static_cast<int>(Next(seed) % 5);
      }
      if (s_rvalid && s_rready) {
        if (s_rlast) { ++r_handshakes; ++req_done; }
        dut->hp0_rvalid = 0;
        dut->hp0_rlast = 0;
        r_wait = -1;
        ar_taken = false;
        ar_delay = static_cast<int>(Next(seed) % 5);
      }

      // The responses, after a small delay of the slave's own.
      if (aw_taken && w_taken && b_wait < 0) b_wait = 1 + static_cast<int>(Next(seed) % 5);
      if (b_wait > 0) --b_wait;
      if (b_wait == 0 && !dut->hp0_bvalid) { dut->hp0_bvalid = 1; dut->hp0_bresp = 0; }
      if (ar_taken && r_wait < 0) r_wait = 1 + static_cast<int>(Next(seed) % 5);
      if (r_wait > 0) --r_wait;
      if (r_wait == 0 && !dut->hp0_rvalid) {
        uint64_t beat = 0;
        if (ar_addr >= kMainBase && ar_addr + 7u < kMainBase + 4ull * kMainWords) {
          const size_t w0 = (ar_addr - kMainBase) >> 2;
          beat = (static_cast<uint64_t>(main_mem[w0 + 1]) << 32) | main_mem[w0];
        } else {
          ++mem_outside;
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

      // A transfer has written a slot: the pack holds the block only once
      // this side has taken it out again.
      if (dut->ch_wrote) feeder.wrote(dut->ch_slot);
      if (dut->ch_hit) feeder.hit(dut->ch_slot, static_cast<uint64_t>(t));

      // ------------------------------------------------------- CLAUSE 5
      if (dut->ch_active && !ch_was) {
        ch_up_at = t;
        page_writes.clear();
        served_this_transfer.clear();
      }
      if (!dut->ch_active && ch_was) {
        // A START that starts no walk raises `ch_active` for two ticks.
        if (t - ch_up_at > 8) {
          ++transfers;
          for (const auto &kv : page_writes) {
            // A page the CHANNEL FILLED took 256 words in this transfer.  A
            // page that took fewer is the processor's own and is not this
            // clause's business; a page that took more has already broken
            // clause 1 at the port.
            if (kv.second != kPageWords) { ++pages_partial; continue; }
            ++pages_checked;
            const size_t base = kv.first * kPageWords;
            const uint32_t first = main_mem[base];
            bool ok = IsPackWord(first) && PackIndex(first) == 0;
            const uint32_t lba = ok ? PackLba(first) : 0u;
            if (ok && !served_this_transfer.count(lba)) ok = false;
            for (int i = 0; ok && i < kPageWords; ++i) {
              const uint32_t got = main_mem[base + i];
              if (!IsPackWord(got) || PackLba(got) != lba || PackIndex(got) != i)
                ok = false;
            }
            if (!ok) {
              ++pages_wrong;
              std::printf(
                  "A PAGE THE CHANNEL FILLED IS NOT A BLOCK OF THE PACK\n"
                  "    physical page %zu (words %zu..%zu), transfer %ld, "
                  "microcycle %" PRIu64 "\n"
                  "    the feeder served these blocks in it:",
                  kv.first, base, base + kPageWords - 1, transfers, micro);
              for (uint32_t l : served_this_transfer) std::printf(" %u", l);
              std::printf("\n    the first eight words are:");
              for (int i = 0; i < 8; ++i) std::printf(" %08x", main_mem[base + i]);
              std::printf("\n");
              std::fflush(stdout);
            }
          }
        }
      }
      ch_was = dut->ch_active;
    }

    if (dut->clock_edge) ++micro;

    dut->clk = 0;
    dut->eval();

    if (transfers >= kWantTransfers) {
      stopped = "enough transfers have been made";
      break;
    }
  }

  const unsigned final_pc = dut->pc;
  const int promdis = dut->promdisable;
  dut->final();
  delete dut;

  // ------------------------------------------------------------ the report
  std::printf(
      "axi channel: %" PRIu64 " microcycles in %ld ticks, PC %o at the end, "
      "PROMDISABLE %d\n"
      "  stopped: %s\n"
      "  processor bus cycles   %ld  (memory %ld, device %ld, Unibus %ld, "
      "NXM %ld)\n"
      "  the pack side          %ld blocks served at a disk address the "
      "controller posted,\n"
      "                         %zu of them distinct, %ld fetched into a "
      "slot, %ld written back,\n"
      "                         %ld denied, %ld refills declined, %ld "
      "refused and asked again\n"
      "  the pack side's ports  %ld GP0 writes, %ld GP0 reads; HP2 %ld read "
      "bursts of %ld beats,\n"
      "                         %ld write bursts of %ld beats\n"
      "  the channel            %ld transfers\n"
      "  memory port requests   %ld  (%ld reads, %ld writes)\n"
      "  AXI address handshakes %ld AR, %ld AW; answers %ld R-last, %ld B, "
      "%ld W\n"
      "  clause 5               %ld pages the channel filled decoded, %ld of "
      "them wrong, %ld partial\n"
      "  clause 4               %ld words read back and compared against the "
      "store\n"
      "  clauses 6 and 7        applied to %ld requests, skipped on %ld with a "
      "transfer in flight\n"
      "  clause 8               %ld main-memory bus cycles, %ld of which asked "
      "the port for nothing\n",
      micro, t, final_pc, promdis, stopped,
      cycles, mem_cycles, dev_cycles, ub_cycles, nxm_cycles,
      feeder.served, served_lbas.size(), feeder.served, feeder.written_back,
      feeder.denied, feeder.declined_already_held, feeder.refusals,
      gp0.writes, gp0.reads, hp2.read_bursts, hp2.read_beats,
      hp2.write_bursts, hp2.write_beats, transfers,
      req_rises, req_read_rises, req_write_rises,
      ar_handshakes, aw_handshakes, r_handshakes, b_handshakes, w_handshakes,
      pages_checked, pages_wrong, pages_partial, words_read_back,
      decode_applied, decode_skipped, memory_cycles_checked,
      memory_cycles_unasked);
  std::fflush(stdout);

  // ------------------------------------------------------- what is asserted
  //
  // THE GUARDS FIRST.  A clause that never applied passed by not running, and
  // this check has five of them.
  Check(cycles > 0, "the machine ran no bus cycle at all");
  Check(mem_cycles >= 512,
        "%ld main-memory bus cycles, wanting at least the boot PROM's 512",
        mem_cycles);
  // WITH A DRIVE ON THE CABLE THE PROM STOPS POLLING, so the device count
  // here is hundreds and not the 88,695 `tb/cadr_bus_audit_tb.cpp` reports
  // with the cable empty.  The guard is still a guard: clause 7 has to have
  // something to apply to.
  Check(dev_cycles + ub_cycles + nxm_cycles >= 100,
        "only %ld device, %ld Unibus and %ld NXM bus cycles: clause 7 is not "
        "being exercised", dev_cycles, ub_cycles, nxm_cycles);
  Check(transfers >= kWantTransfers,
        "%ld disk transfers, wanting %ld: the channel is the whole reason this "
        "check exists and a run that never reached it has tested the boot "
        "PROM again", transfers, kWantTransfers);
  Check(pages_checked >= kWantPages,
        "%ld pages the channel filled were decoded, wanting %ld: clause 5 is "
        "what says a pack block reached main memory, and a run that decoded "
        "fewer has tested less than it did when this figure was measured",
        pages_checked, kWantPages);
  Check(words_read_back > 0,
        "no read was compared against the store: clause 4 never applied");

  // CLAUSE 1.
  Check(answers_per_request_wrong == 0,
        "%ld requests were answered other than exactly once",
        answers_per_request_wrong);
  Check(txns_per_request_wrong == 0,
        "%ld requests issued other than exactly one transaction of their own "
        "direction", txns_per_request_wrong);
  Check(txns_outside_a_request == 0,
        "%ld AXI transactions went out with no request standing",
        txns_outside_a_request);
  Check(ar_handshakes == req_read_rises && aw_handshakes == req_write_rises,
        "%ld read and %ld write transactions against %ld read and %ld write "
        "requests", ar_handshakes, aw_handshakes, req_read_rises,
        req_write_rises);
  Check(r_handshakes == ar_handshakes && b_handshakes == aw_handshakes &&
        w_handshakes == aw_handshakes,
        "%ld read answers, %ld write answers and %ld write beats against %ld "
        "reads and %ld writes", r_handshakes, b_handshakes, w_handshakes,
        ar_handshakes, aw_handshakes);
  // CLAUSE 2.
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
  Check(mem_misaligned == 0, "%ld requests were not word-aligned",
        mem_misaligned);
  // CLAUSE 3.
  Check(neighbour_disturbed == 0,
        "%ld writes disturbed the other half of their own beat",
        neighbour_disturbed);
  // CLAUSE 4.
  Check(read_lane_wrong == 0,
        "%ld reads came back with a word the store does not hold at the "
        "address the bridge asked for", read_lane_wrong);
  // CLAUSE 5.
  Check(pages_wrong == 0,
        "%ld of the %ld pages the channel filled are not a block of the pack",
        pages_wrong, pages_checked);
  // CLAUSE 6.
  Check(writes_unasked == 0,
        "%ld writes went out at the port with the processor's WRCYC down and "
        "the channel idle", writes_unasked);
  // CLAUSE 7.
  Check(direction_wrong == 0,
        "%ld transactions went out in a direction the processor's own WRCYC "
        "does not name", direction_wrong);
  Check(non_memory_asked == 0,
        "%ld bus cycles the decode did not call main memory reached the "
        "memory port", non_memory_asked);
  Check(feeder.denied == 0,
        "%ld block requests were denied; every address this program asks for "
        "is on the pack", feeder.denied);

  // ============ THE CLAUSES THE PACK SIDE BEING IN THE DESIGN ADDS =========
  //
  // Clauses 1 to 8 above are `tb/cadr_axi_channel_tb.cpp`'s and are unchanged:
  // they state properties of the words and not of who moved them, which is
  // why they still mean what they meant with one more module under them.
  // These four are new and are about the module itself.
  //
  // 9   THE RECORD ACTUALLY CROSSED HP2.  Without this, a pack side that did
  //     nothing at all would leave the walk waiting and the run would fail on
  //     clause 5 for a reason that names the wrong thing.
  Check(hp2.read_bursts > 0,
        "the pack side never read a record out of DDR: the module is in the "
        "design and nothing crossed its port");
  Check(hp2.read_bursts == 9 * feeder.served,
        "%ld read bursts on HP2 for %ld records served, wanting nine a record "
        "--- eight of sixteen beats for the block and one of two for the "
        "header and the checkwords",
        hp2.read_bursts, feeder.served);
  //
  // 10  THE PORT'S OWN RULES.  One address handshake a burst, as many beats as
  //     the length promised, WLAST and RLAST where it says, no burst across a
  //     4 KB boundary, every beat aligned.  A slave that only recorded the
  //     address could not see a duplicate handshake.
  Check(hp2.bad == 0,
        "%ld AXI3 rules were broken on S_AXI_HP2 by the pack side", hp2.bad);
  Check(gp0.bad == 0, "%ld register accesses on M_AXI_GP0 went wrong", gp0.bad);
  Check(hp2.aw_handshakes == hp2.write_bursts &&
            hp2.b_responses == hp2.write_bursts,
        "%ld write bursts on HP2 against %ld address handshakes and %ld "
        "responses; one of each a burst, or a duplicate went unseen",
        hp2.write_bursts, hp2.aw_handshakes, hp2.b_responses);
  //
  // 11  AND THE ONE THIS HARNESS WAS BUILT FOR.  HP0 and HP2 are two doors
  //     into one DRAM on the board and into one array here, so a pack-side
  //     beat inside the machine's own 22-bit physical space is a word of
  //     somebody else's memory overwritten --- which is the exact shape of
  //     CLAUDE.md's page-hash-table word.  The staging records are at
  //     0x1C80_0000 and up; nothing correct goes anywhere else.
  Check(hp2_in_main == 0,
        "%ld beats of the pack side landed inside the machine's own main "
        "memory", hp2_in_main);
  Check(hp2_outside_staging == 0,
        "%ld beats of the pack side landed outside the staging records Linux "
        "pointed it at", hp2_outside_staging);
  //
  // 12  AND NOTHING WAS REFUSED OR FAULTED.  A refusal is Linux's bug on the
  //     board and would be the testbench's here; the error bit is SLVERR,
  //     DECERR or a burst that did not end where it should.
  Check(feeder.errors == 0,
        "%ld moves came back with the pack side's error bit set",
        feeder.errors);
  // CLAUSE 8.
  Check(memory_cycles_checked > 0,
        "no main-memory bus cycle was seen: clause 8 never applied");
  Check(memory_cycles_unasked == 0,
        "%ld of %ld main-memory bus cycles finished without asking the port "
        "for their own address, so something answered them that was not the "
        "memory", memory_cycles_unasked, memory_cycles_checked);

  if (fails) {
    std::fprintf(stderr, "axi channel: %d failure%s\n", fails,
                 fails == 1 ? "" : "s");
    return 1;
  }
  std::printf(
      "axi channel: ok --- %ld pack blocks reached main memory through the "
      "channel,\n"
      "    the bridge, `cadr_axi_master` and `cadr_axi_widen`, and every page "
      "decodes\n"
      "    as the block the feeder served, words 0 to 255 in order; every "
      "transaction\n"
      "    was one beat at the word's own address with the strobes of the half "
      "the\n"
      "    address names, disturbed no other half, and came back with the word "
      "the\n"
      "    store holds\n",
      pages_checked);
  return 0;
}
