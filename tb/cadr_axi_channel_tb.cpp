// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A BLOCK OF A PACK, THROUGH THE CHANNEL, THROUGH THE ADAPTER AND THE
// WIDENING, INTO A 64-BIT BEAT --- AND OUT AGAIN WORD FOR WORD.
//
// **THE HOLE THIS IS AIMED AT.**  CLAUDE.md's account of the board's
// page-hash-table word ends with a bounded suspect list.  `make hash-watch`
// runs `cadr_machine` from reset off a real pack with a modelled DDR and
// reaches 171,000,000 microcycles with the board's fingerprint occurring zero
// times, so the defect is not in `rtl/machine/`.  What that harness replaces
// with a model is what is left: between `cadr_machine`'s `mem_*` port and the
// DRAM the board has `cadr_axi_master`, `cadr_axi_widen`, the PS7 and the DDR3
// controller.
//
// And **no check in this tree had ever run a real program through that
// composition**.  `axi_master.pass` and `axi_widen.pass` hold each module
// alone.  `mem_count.pass` and `bus_audit.pass` compose them, and both are
// deliberately MIT's boot PROM with NO DRIVE ON THE CABLE: 512 identity memory
// cycles, one word at a time, and `tb/cadr_bus_audit_tb.cpp` asserts outright
// that the disk channel never took the bus.  So the second Xbus master --- 256
// words a page through a per-word arbiter --- had never crossed the widening
// at all, and neither had a program that reads back what it wrote.
//
// **WHAT THIS RUNS.**  MIT's boot PROM from reset with ONE DRIVE ON THE CABLE
// and a pack behind the block store's seam, so that the cold boot's own
// `COLD-DISK-READ` happens: a CCW list, blocks into consecutive physical
// pages, 256 bus cycles a page, every word of every page crossing
// `cadr_axi_master` and `cadr_axi_widen` into the 64-bit AXI3 slave modelled
// here.  The run stops when enough transfers have been made, so nothing in it
// depends on what the machine does after the microcode is loaded.
//
// **THE PACK IS SYNTHETIC AND IT IS POISON, INJECTIVE IN THE DISK ADDRESS.**
// Word `i` of block `l` is `0xA8000000 | l << 8 | i`, which is decodable: the
// top six bits are a marker no word of this program otherwise carries, and the
// rest name the block and the word's place in it.  So a page of main memory
// can be READ BACK AND DECODED without the testbench being told where the CCW
// walk put it --- which is what keeps this from being a shadow memory.
// CLAUDE.md's rule is that a check keyed by the thing under test moves with
// the bug; here the testbench knows only what it SERVED at the seam, and what
// it finds in memory has to decode to that on its own.
//
// No file: a pack of 263,245 blocks is generated a block at a time on demand,
// which is what lets this run under `mutations/run.py` with nothing copied.
//
// **THE EIGHT CLAUSES.**
//
//   1  ONE ANSWER PER REQUEST, and one address handshake of its own direction,
//      and none at all while no request stands.  `tb/cadr_bus_audit_tb.cpp`
//      holds this for the boot PROM alone; here a second master is putting
//      requests through the same adapter.
//
//   2  THE BEAT IS THE WORD'S OWN.  `m_awaddr`/`m_araddr` are the bridge's
//      address with the low three bits cleared, the write strobes are the four
//      bytes of the half `A[2]` names, and the beat carries the word in BOTH
//      halves.  Checked transaction by transaction rather than on a directed
//      stimulus.
//
//   3  A WRITE DISTURBS ONLY ITS OWN HALF, held by DATA: the neighbouring word
//      of the beat is a real and different word of the machine's memory, and a
//      strobe pattern covering it destroys that word silently.
//
//   4  THE WORD READ BACK IS THE WORD THE STORE HOLDS AT THE ADDRESS THE
//      BRIDGE ASKED FOR.  This is the whole read path --- adapter, widening,
//      lane select --- in one line, and it is the clause a lane taken from the
//      wrong channel falls over.
//
//   5  A PAGE THE CHANNEL FILLED IS A BLOCK OF THE PACK.  At the end of every
//      transfer, every 256-word page that took 256 writes during it must
//      decode as one block, words 0 to 255 in order, whose disk address the
//      feeder actually served.  A dropped address bit, a half-select that went
//      the wrong way, a duplicated word and a reordered word are all visible
//      here and in no other check in this tree.
//
//   6  A WRITE NOBODY ASKED FOR.  `mem_write` up at the port with the
//      processor's own WRCYC down and the channel idle.  That is CLAUDE.md's
//      account of the board's corruption written as an invariant rather than
//      as an address, and it is the reason this family of checks exists.
//
//   7  A CYCLE THE DECODE DID NOT CALL MAIN MEMORY ISSUES NOTHING.  The
//      processor's own `device`/`unibus`/`nxm`, applied while no transfer is
//      in flight.  `ch_own` is not a port of `cadr_machine`, so a transaction
//      cannot be attributed to an owner from outside while the channel is
//      running; rather than widen the clause until it says nothing, it is
//      applied where it is exact and the requests it skipped are counted and
//      printed.
//
//   8  AND A CYCLE THE DECODE DID CALL MAIN MEMORY ASKS THE PORT FOR ITS OWN
//      ADDRESS.  The other half of clause 7.  Every clause above counts or
//      inspects TRANSACTIONS, so a fault that answers a processor cycle
//      without one is invisible to all of them; this is that gap closed.  The
//      comment at the clause says what it was written for and measures that it
//      does not catch it, which is worth more than the clause.
//
// **WHAT THIS CANNOT DO**, said at the top because a check that passes while
// testing nothing is this repository's commonest failure.  It is not compared
// against muir: there is no reference for a fabric channel, `Controller::
// transfer` writing `main` directly and finishing at the instant it starts, so
// this is held to properties in the way `axi_master.pass` is.  And the board's
// own event is one in about a hundred and seventy-six million microcycles,
// while this is a few hundred thousand; green here means the properties hold
// for the program we can run, not that the board is clean.  `make band-axi` is
// the same composition run to the board's own fault, and it is not a check.

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

#include "Vcadr_band_axi_harness.h"
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

  auto *dut = new Vcadr_band_axi_harness;
  dut->clk = 0;
  dut->rst = 1;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  dut->drive_present = 0x01;
  dut->drive_read_only = 0x00;
  dut->drive_timed = 0;
  dut->store_we = 0;
  dut->store_slot = 0;
  dut->store_addr = 0;
  dut->store_wdata = 0;
  dut->store_busy = 0;
  dut->store_busy_slot = 0;
  dut->store_deny = 0;
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
  // The far end of the block store's seam, as `rtl/plumbing/cadr_disk_pack.sv`
  // drives it and in its order: the slot is taken away first, its 256 data
  // words and three meta words go in one a tick, and the TAG goes in LAST ---
  // so a walk reaching the slot during the fill misses it and waits, rather
  // than reading a block half old and half new.
  constexpr int kSlots = 24;
  constexpr int kStHeader = 256, kStHck = 257, kStDck = 258, kStTag = 259;
  enum Feeder { F_IDLE, F_EVICT, F_FILL };
  Feeder feeder = F_IDLE;
  int f_slot = 0, f_step = 0;
  uint32_t f_words[kBlockWords];
  uint32_t f_hdr = 0, f_hck = 0, f_dck = 0, f_tag = 0;
  std::vector<uint32_t> slot_tag(kSlots, 0);
  std::vector<uint8_t> slot_valid(kSlots, 0), slot_dirty(kSlots, 0);
  std::vector<uint64_t> slot_used(kSlots, 0);
  std::vector<uint32_t> evict_buf(kBlockWords, 0);
  std::map<uint32_t, std::vector<uint32_t>> written_back;
  int next_slot = 0;
  long fills = 0, evictions = 0, denials = 0, refill_declined = 0;
  // WHAT THE FEEDER SERVED, which is the only thing this testbench knows
  // about where the pack's words came from.  Clause 5 requires a page in
  // memory to decode to one of these on its own.
  std::set<uint32_t> served_lbas;
  std::set<uint32_t> served_this_transfer;

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
    dut->store_we = 0;
    dut->store_deny = 0;
    const bool walk_holds = dut->ch_active && !dut->ch_waiting;
    if (feeder == F_IDLE) {
      dut->store_busy = 0;
      if (dut->req_valid) {
        const uint32_t tag = dut->req_tag;
        const uint32_t unit = (tag >> 28) & 7u;
        const uint32_t c = (tag >> 16) & 0xFFFu;
        const uint32_t h = (tag >> 8) & 0xFFu;
        const uint32_t b = tag & 0xFFu;
        // `req_valid` is a LEVEL that stands from the post until the store's
        // tag is written with the block, and `cadr-disk-pack` on the board
        // acts on the POST and on what it has already served --- so it fills
        // a slot once.  A feeder that fills on the level refills the same
        // block for ever if the walk does not take it.
        bool already = false;
        for (int s2 = 0; s2 < kSlots; ++s2)
          if (slot_valid[s2] && slot_tag[s2] == (tag & 0x7FFFFFFFu)) already = true;
        if (already) {
          ++refill_declined;
        } else if (unit != 0 || !OnPack(c, h, b)) {
          if (dut->ch_waiting) { dut->store_deny = 1; ++denials; }
        } else {
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
            const uint32_t lba = Lba(c, h, b);
            // THE PACK, GENERATED ON DEMAND: poison injective in the disk
            // address, and decodable, so that what lands in main memory can
            // be read back without the testbench saying where it went.  A
            // block the machine has written back is served as it wrote it,
            // exactly as muir's `Unit::written` keeps it.
            auto it = written_back.find(lba);
            if (it != written_back.end())
              std::memcpy(f_words, it->second.data(), kBlockWords * 4);
            else
              for (int i = 0; i < kBlockWords; ++i) f_words[i] = PackWord(lba, i);
            served_lbas.insert(lba);
            served_this_transfer.insert(lba);
            f_hdr = HeaderOf(c, h, b);
            const uint8_t hb[4] = {
                static_cast<uint8_t>(f_hdr), static_cast<uint8_t>(f_hdr >> 8),
                static_cast<uint8_t>(f_hdr >> 16), static_cast<uint8_t>(f_hdr >> 24)};
            f_hck = Ecc::over_bytes(hb, 4);
            f_dck = Ecc::over_words(f_words, kBlockWords);
            f_step = 0;
            feeder = (slot_valid[f_slot] && slot_dirty[f_slot]) ? F_EVICT : F_FILL;
            if (feeder == F_EVICT) ++evictions;
            dut->store_busy = 1;
            dut->store_busy_slot = f_slot;
          }
        }
      }
    } else if (feeder == F_EVICT) {
      dut->store_busy = 1;
      dut->store_busy_slot = f_slot;
      dut->store_slot = f_slot;
      if (f_step < kBlockWords) dut->store_addr = f_step;
      if (f_step >= 2 && f_step - 2 < kBlockWords)
        evict_buf[f_step - 2] = dut->store_rdata;
      ++f_step;
      if (f_step >= kBlockWords + 2) {
        const uint32_t tag = slot_tag[f_slot];
        written_back[Lba((tag >> 16) & 0xFFFu, (tag >> 8) & 0xFFu, tag & 0xFFu)]
            .assign(evict_buf.begin(), evict_buf.end());
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
        slot_used[f_slot] = static_cast<uint64_t>(t);
      }
      ++f_step;
      if (f_step > kBlockWords + 4) { feeder = F_IDLE; ++fills; }
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

    dut->clk = 1;
    dut->eval();

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
      if (dut->ch_wrote) slot_dirty[dut->ch_slot] = 1;
      if (dut->ch_hit) slot_used[dut->ch_slot] = static_cast<uint64_t>(t);

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
      "                         %zu of them distinct, %ld fills, %ld "
      "evictions, %ld denials,\n"
      "                         %ld refills declined\n"
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
      static_cast<long>(fills), served_lbas.size(), fills, evictions, denials,
      refill_declined, transfers,
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
  Check(denials == 0,
        "%ld block requests were denied; every address this program asks for "
        "is on the pack", denials);
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
