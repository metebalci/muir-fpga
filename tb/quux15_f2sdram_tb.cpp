// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX revision 15's memory master behind the DE25-Nano's memory port:
// `rtl/plumbing/quux15_axi_master.sv` through
// `rtl/plumbing/quux15_f2sdram_port.sv` (`tb/quux15_f2sdram_harness.sv`)
// against a model of the Agilex 5's FPGA-to-SDRAM bridge, with the disk
// pack side and the display as the share's two other masters.  It is
// `tb/cadr_f2sdram_tb.cpp`'s question for revision 15's master, which the
// CADR's boot PROM cannot ask: line fills of five beats, posted word writes
// of one or two beats, bursts split at 4 KiB, one write ID.
//
// THE MASTER'S PORT SIDE is played as `quux15_port.sv` plays it, as
// `tb/quux15_axi3_tb.cpp` plays it: each word write offered while `w_free`
// and held until `w_taken`, up to sixteen unanswered, each answered once and
// in order (`b_done`, `b_id`), none to a line whose read is out; each line
// read held until `ar_taken`, one at a time, after every write to its line
// is answered, its 40 bytes at `rd_last` the bridge's.  Main memory is
// packed storage from the DE25-Nano's base, 0xA000_0000: word w at byte 5w,
// line L at 40L; one word in two runs into a second beat, and some into the
// next 4 KiB page.  The other two masters are the testbench's: the pack side
// writes one or two sixteen-beat bursts into a region of its own, the second
// offered before the first is answered, and reads them back; the display
// reads the frame buffer at 0xB400_0000, whose words are a function of their
// address, a line at a time as one burst of sixteen beats, or a rotated
// band's 64 single beats with up to eight in flight.
//
// THE BRIDGE'S RULES, ON EVERY TRANSACTION (`cadr_f2sdram_share.sv`'s
// header, from the Agilex 5 HPS TRM, document 814346, section 11.8.3.1):
// eight bytes a beat, INCR, AxUSER 0xE0, AxCACHE 0b0010, AxPROT 0b011, no
// lock, QoS or region; and AXI's own: no burst across 4 KiB, a valid and its
// payload held until taken, every address its burst of beats with WLAST on
// the last, write data in the order of the write addresses.  **AND THE IDS
// ARE THE SHARE'S PORT NUMBERS**: the machine's transactions carry 0 and
// touch main memory alone, the pack side's 1, the display's 2, and every
// answer reaches the master whose ID it carries --- which is where a share
// wired with two ports crossed shows.  The bridge answers each ID's writes
// in order and different IDs' in any order, so a response routed to the
// wrong master, or a write of the machine's given an ID of its own, shows.
// **THE WRITES UNANSWERED AT THE BRIDGE**, counted by ID: the pack side one
// at most, the machine sixteen (its master's in-flight list), and in BUSY
// at least four at once, the share posting them.
//
// THE CONFIGURATIONS.
//
// THE CORE'S RESET is played here as `quux15_core.sv` takes it (its
// `rq_*`), since this file is the core's port side: the processor's reset,
// which the board's top gives the core as its hard reset, at once; a
// request --- the testbench's, a clock long, or the port not yet live, as
// the top asks --- latched, the port side then offering nothing new, and the
// master reset once nothing of its is open, for 64 clocks at least and while
// the request stands.  The share must let that drain finish: nothing in the
// port holds it for the machine's reset.
//
//   OPEN       the processor in reset at first, then out of it with the port
//              shut, then software opens it.  The master is held in reset
//              (`mach_rst`) until the port is live and let go within
//              `kReleaseBound` clocks of it; nothing reaches the bridge
//              before the port opens; then the traffic, and at the end every
//              byte written is memory's and the tally reads, in both
//              halves, what the bridge answered and was asked.
//   HELD       software shuts the port under a stream of writes and opens it
//              again: from `kHeldSlack` clocks after the shut nothing new is
//              put to the bridge, writes stand queued at the master the whole
//              time, the machine is not reset, and once the port opens every
//              queued write lands, in order.
//   RESET      the machine's reset asked for in the middle of the traffic, a
//              clock at a time: the drain ends within `kDrainBound` clocks,
//              the share granting the master what it owes; at the reset the
//              bridge holds nothing of the machine's, no fill the master took
//              is still to come and no write is unanswered, split at 4 KiB
//              or not; and every fill after it is the bridge's line, with no
//              beat of an older one in it.
//   HANDSHAKE  the processor asks the fabric to be quiet: from `kHeldSlack`
//              clocks after the request nothing new is put to the bridge,
//              the acknowledgment comes only once nothing is outstanding,
//              and the traffic resumes when the request goes away.
//   HPS        the processor resets: the bridge forgets what it had, the
//              port goes into reset at once, the machine is reset with it
//              (as the board's top asks), and after software opens the port
//              again every fill is the bridge's line.
//   BUSY       the pack side and the display streaming the whole time, the
//              machine's writes back to back.
//   ZERO       the same, the writes at cons's zeroing rate, one every 5
//              clocks (`czrr1`, 5.01 clocks a word; muir-sim's profile at the
//              DE25's 27 ns, 16K cache and 410,290,40 gives cons one write
//              per 5.84 clocks).
//   BITBLT     the same at bitblt's, one write every 16 clocks (the same
//              profile: 16.6).
//   FILLS      the same with the machine's line fills back to back, a write
//              every 32 clocks: the reads that hold the others.
//   FLOOD      BUSY with the pack side and the display asking again the
//              clock each finishes: the bound must leave the machine its
//              share.
//
// **NEITHER OTHER MASTER STARVES** in BUSY, ZERO, BITBLT and FILLS: no read
// of the display's waits past a raster line, 579 clocks at 27 ns, and no
// rotated band of 64 of its reads takes longer than its share of the 32
// lines one word column covers, 1,231 clocks; no burst of the pack side's
// waits past 600 clocks; and in these and FLOOD no write of the machine's
// waits past 400 clocks from its offer to its accept, nor a fill to its last
// beat.  Each run prints the machine's write occupancy
// (from a write's offer to its accept) and fill latency, and the other two
// masters' longest waits.
//
// **THE LATENCY PROBE** (`quux15_mem_probe.sv`) is started with the traffic
// under way and stopped at the end; its eight figures must be those of the
// machine's handshakes at the bridge timed here, from an address taken to
// its last read beat or its response.
//
// Each configuration runs under three seeds and two sets of readies.

#include <algorithm>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <vector>

#include "Vquux15_f2sdram_harness.h"
#include "verilated.h"

namespace {

constexpr uint64_t kBase = 0xA0000000ull;        // main memory (`QUUX13_MAIN_BASE`)
constexpr uint64_t kDisplayBase = 0xB4000000ull;  // the frame buffer (`DISPLAY_BASE`)
constexpr uint64_t kPackBase = 0xA8000000ull;     // the pack side's own region
constexpr uint32_t kWords = 1u << 15;             // the words a run touches
constexpr size_t kBytes = size_t(kWords) * 5 + 64;
constexpr size_t kPackBytes = 64 * 128;           // 64 bursts of 16 beats
constexpr int kMachine = 0, kPack = 1, kDisplay = 2;
// From the port going live to the master out of reset: `may_start` the clock
// after `live`, `pend_n` the clock after that, and `run` the next.
constexpr long kReleaseBound = 3;
// A drain through the share, the bridge answering in its own time: far
// above what one takes, far below the core's bound of 2^16.
constexpr long kDrainBound = 4000;
// From the shut, the request or the processor's reset at the port's pins to
// the share granting nothing new: three synchronizer stages, the gate's
// `hold`, and a grant registered on the edge before it.
constexpr long kHeldSlack = 5;

enum Config { kOpen, kHeld, kReset, kHandshake, kHps, kBusy, kZero, kBitblt, kFills, kFlood };
const char *config_name(Config c) {
  switch (c) {
    case kOpen: return "OPEN";
    case kHeld: return "HELD";
    case kReset: return "RESET";
    case kHandshake: return "HANDSHAKE";
    case kHps: return "HPS";
    case kBusy: return "BUSY";
    case kZero: return "ZERO";
    case kBitblt: return "BITBLT";
    case kFills: return "FILLS";
    default: return "FLOOD";
  }
}

// The clocks between two writes the port side offers, by configuration: 0
// back to back.  ZERO is cons's zeroing loop, a word every 5 clocks
// (`czrr1`, 5.01 clocks a word; muir-sim's profile at 27 ns, 16K, 410,290,40
// gives cons one write per 5.84 clocks); BITBLT is bitblt's whole run, one
// write per 16.6 clocks; FILLS and HANDSHAKE leave room for the reads.
long write_interval(Config c) {
  switch (c) {
    case kZero: return 5;
    case kBitblt: return 16;
    case kHandshake: return 16;
    case kFills: return 32;
    default: return 0;
  }
}

// **THE DISPLAY'S LINE BUDGET**: a raster line of 1280x1024 at 60 Hz is
// 1,688 pixels at 108 MHz, 15.63 us, and the display asks for a line's words
// (or a band's next word) one line ahead.  579 clocks is that line at 27 ns,
// longer than any period this board's revision 15 is built at (22.5 ns, its
// binding fit's), so fewer clocks than a line has.  No read of the
// display's may wait longer.
constexpr long kLineBudget = 579;
// The pack side has no raster, but it must not starve: no burst of its may
// wait longer than this from its valid to its answer.
constexpr long kPackBudget = 600;
// **AND THE MACHINE NOT STARVED BY THE BOUND**: no write of its waits longer
// than this from its offer to its accept, and no fill from its request to
// its last beat (measured at most 121 beside the others' streams).
constexpr long kMachineBound = 400;
// The writes one master may have unanswered at the bridge: the machine's
// in-flight list, and one for the pack side.
constexpr long kMachineWrites = 16;
// A rotated band's single-beat reads, as `cadr_display_out.sv` asks them:
// up to `OUTSTANDING` (8) at once, here 64 to a job.  **AND ITS BUDGET**: a
// band of the first display is 963 words in the 32 lines one word column
// covers, 32 x 579 clocks at 27 ns, so 64 of its reads have 64 x 32 x 579 /
// 963 = 1,231 clocks.
constexpr unsigned kBandReads = 64, kBandOutstanding = 8;
constexpr long kBandBudget = 64 * 32 * kLineBudget / 963;

struct Rng {
  uint64_t s;
  uint64_t next() {
    s ^= s >> 12;
    s ^= s << 25;
    s ^= s >> 27;
    return s * 0x2545F4914F6CDD1Dull;
  }
  bool chance(unsigned pct) { return next() % 100 < pct; }
  uint32_t below(uint32_t n) { return static_cast<uint32_t>(next() % n); }
};

uint64_t DisplayBeat(uint64_t a) { return 0xD15C0000D15C0000ull ^ (a * 0x9E3779B97F4A7C15ull); }

struct Burst {
  int id;
  uint64_t addr;
  unsigned len, sent;
};

struct Beat {
  uint64_t data;
  unsigned strb;
  bool last;
};

struct Run {
  uint64_t seed;
  Config cfg;
  unsigned ready_pct;
  Vquux15_f2sdram_harness *d;
  Rng rng;
  long t = 0, bad = 0;

  void fail(const char *what) {
    if (bad < 10)
      std::fprintf(stderr, "seed %" PRIu64 ", %s, readies %u%%, clock %ld: %s\n", seed, config_name(cfg),
                   ready_pct, t, what);
    ++bad;
  }

  // --- the bridge -----------------------------------------------------------
  std::vector<uint8_t> mem, want, unsure, pack_mem;
  std::deque<Burst> aw_q, ar_q;
  std::deque<Beat> w_early;
  std::deque<std::pair<int, long>> b_due;   // ID, the clock it may be answered
  int b_pick = -1;                           // the one offered this clock
  long wr_at[32] = {};                       // writes unanswered at the bridge, by ID
  long wr_at_most = 0;                       // the machine's, at the most
  long r_wait = -1;
  // What stood on each address channel unaccepted at the last edge.
  bool aw_held = false, ar_held = false, w_held = false;
  uint64_t aw_was = 0, ar_was = 0, w_was = 0;
  bool aw_prev = false, ar_prev = false;     // a valid at the last edge, not taken
  long new_after = -1;                       // no new address from this clock on
  long new_addresses_late = 0;

  // --- the tally, as the bridge's handshakes say it should read --------------
  long ans_r = 0, ans_w = 0, ask_r = 0, ask_w = 0;
  bool creq_q = false, cwrite_q = false, creq_qq = false;

  // --- the machine's port side ------------------------------------------------
  struct Wr {
    uint32_t w;
    uint64_t word;
  };
  std::deque<Wr> to_write;
  std::vector<int> pending;
  struct Fl {
    uint32_t w, line;
    bool split;
  };
  std::deque<Fl> inflight;
  bool w_on = false, ar_on = false, rd_wait = false;
  Wr cur{};
  uint32_t cur_line = 0, next_id = 0, ans_id = 0;
  long writes = 0, reads = 0, splits = 0, two_beat = 0, resets = 0, queued_while_shut = 0;
  bool mach_rst_prev = true;
  // The core's reset rule (the header): the request, its state, its clocks.
  enum { kCoreRun, kCoreDrain, kCoreReset } core = kCoreReset;
  bool tb_req = false;
  long core_count = 0, drain_from = -1, longest_drain = 0;
  bool stopped = false;   // the port side asks nothing more: the tally is read
  long live_rise = -1, released = -1, last_reset = -1;

  // --- the latency probe, timed here at the same handshakes -----------------
  // A latency counts when its answer came in [`pr_run_at`, `pr_stop_at`).
  std::deque<long> pr_rq, pr_wq;
  long pr_run_at = -1, pr_stop_at = -1;
  uint64_t pr_rc = 0, pr_rs = 0, pr_rm = 0, pr_wc = 0, pr_ws = 0, pr_wm = 0;
  bool pr_counted(long at) const { return pr_run_at >= 0 && at >= pr_run_at && (pr_stop_at < 0 || at < pr_stop_at); }
  // Two runs: stopped and read 3,000 clocks after the first RUN, with the
  // traffic under way, then RUN again, which must clear every figure.
  int pr_phase = 0;
  uint64_t pr_rc1 = 0, pr_wc1 = 0;

  void probe_check(const char *when) {
    auto word = [&](int k) { return static_cast<uint64_t>(d->probe_words[k]); };
    const uint64_t got[8] = {word(0), word(1), word(2), word(3), word(4), word(5), word(6), word(7)};
    const uint64_t want[8] = {pr_rc & 0xFFFFFFFFu, pr_rs & 0xFFFFFFFFu, (pr_rs >> 32) & 0xFFFFu, pr_rm,
                              pr_wc & 0xFFFFFFFFu, pr_ws & 0xFFFFFFFFu, (pr_ws >> 32) & 0xFFFFu, pr_wm};
    static const char *names[8] = {"reads",  "the reads' sum",  "the reads' sum's top",  "the longest read",
                                   "writes", "the writes' sum", "the writes' sum's top", "the longest write"};
    for (int k = 0; k < 8; ++k)
      if (got[k] != want[k]) {
        char why[200];
        std::snprintf(why, sizeof why, "%s, the probe's %s reads %" PRIu64 ", and the bridge's handshakes give %" PRIu64,
                      when, names[k], got[k], want[k]);
        fail(why);
      }
    if (d->probe_state != 0) {
      char why[120];
      std::snprintf(why, sizeof why, "%s, the probe's state reads %u after its stop, wanting 0", when,
                    unsigned(d->probe_state));
      fail(why);
    }
  }

  // --- what the port side measures ------------------------------------------
  long last_offer = -100000, w_offer_t = 0, occ_sum = 0, occ_max = 0, first_taken = -1, last_taken = -1;
  long fill_t = 0, fill_sum = 0, fill_max = 0, fills = 0;

  // --- the other two masters ------------------------------------------------
  bool others = false;
  // Pack: one or two sixteen-beat writes to pages of its own, the second
  // offered as soon as the first's address and beats are taken, before its
  // response; then the same pages read back, the second address offered as
  // soon as the first is taken.
  int pk_state = 0;   // 0 idle, 1 writing, 2 awaiting the responses, 3 reading
  unsigned pk_n = 0, pk_pages[2] = {0, 0}, pk_wi = 0, pk_beat = 0, pk_bs = 0, pk_ri = 0, pk_rj = 0, pk_rbeat = 0;
  bool pk_aw_done = false;
  long pk_wstart[2] = {0, 0}, pk_rstart[2] = {0, 0};
  long pk_gap = 0, pk_bursts = 0, pk_worst = 0;
  // Display: a job is a line, one read of sixteen beats, or a rotated band's
  // `kBandReads` single beats with up to `kBandOutstanding` in flight.
  struct DpRead {
    uint64_t addr;
    unsigned len;
    long start;
  };
  int dp_state = 0;   // 0 idle, 1 a job
  bool dp_band = false;
  uint64_t dp_base = 0;
  unsigned dp_reads = 0, dp_issued = 0, dp_done = 0, dp_beat = 0;
  std::deque<DpRead> dp_q;
  long dp_since = -1, dp_job_start = 0;
  long dp_gap = 0, dp_bursts = 0, dp_worst = 0, dp_band_worst = 0, dp_bands = 0;
  uint64_t dp_addr_of(unsigned k) const {
    return dp_band ? kDisplayBase + (dp_base + 96ull * k) % 0x100000 : kDisplayBase + dp_base;
  }

  Run(uint64_t s, Config c, unsigned r) : seed(s), cfg(c), ready_pct(r), rng{s * 0x9E3779B97F4A7C15ull + c * 7 + r} {
    d = new Vquux15_f2sdram_harness;
    mem.resize(kBytes);
    want.resize(kBytes);
    unsure.assign(kBytes, 0);
    pack_mem.assign(kPackBytes, 0);
    for (size_t i = 0; i < kBytes; ++i) mem[i] = want[i] = static_cast<uint8_t>(rng.next());
    pending.assign(kWords / 8 + 2, 0);
    others = (c == kBusy || c == kHandshake || c == kZero || c == kBitblt || c == kFills || c == kFlood);
  }
  ~Run() { delete d; }

  bool at_main(uint64_t a) { return a >= kBase && a + 8 <= kBase + kBytes; }

  // The bridge forgets everything it had: the processor's own reset.
  void bridge_reset() {
    for (auto &n : wr_at) n = 0;
    pr_rq.clear();
    pr_wq.clear();
    aw_q.clear();
    ar_q.clear();
    w_early.clear();
    b_due.clear();
    r_wait = -1;
    aw_held = ar_held = w_held = false;
    aw_prev = ar_prev = false;
  }

  void land(Burst &b, const Beat &w) {
    const uint64_t a = b.addr + 8ull * b.sent;
    for (int k = 0; k < 8; ++k)
      if ((w.strb >> k) & 1) {
        if (b.id == kMachine && at_main(a)) mem[a + k - kBase] = static_cast<uint8_t>(w.data >> (8 * k));
        else if (b.id == kPack && a >= kPackBase && a + 8 <= kPackBase + kPackBytes)
          pack_mem[a + k - kPackBase] = static_cast<uint8_t>(w.data >> (8 * k));
        else fail("a write beat outside the region of the master whose ID it carries");
      }
    ++b.sent;
    if (w.last != (b.sent == b.len)) fail("WLAST not on the burst's last beat");
    if (b.sent == b.len) b_due.push_back({b.id, t + 2 + static_cast<long>(rng.below(20))});
  }

  uint64_t read_beat(const Burst &b) {
    const uint64_t a = b.addr + 8ull * b.sent;
    uint64_t v = 0;
    if (b.id == kMachine) {
      for (int k = 0; k < 8; ++k) v |= uint64_t(at_main(a) ? mem[a - kBase + k] : 0xA5) << (8 * k);
    } else if (b.id == kPack) {
      for (int k = 0; k < 8; ++k) {
        const uint64_t o = a - kPackBase + k;
        v |= uint64_t(o < kPackBytes ? pack_mem[o] : 0x5A) << (8 * k);
      }
    } else {
      v = DisplayBeat(a);
    }
    return v;
  }

  void check_address(const char *ch, int id, uint64_t addr, unsigned len, unsigned size, unsigned burst,
                     unsigned user, unsigned cache, unsigned prot, unsigned lock, unsigned qos, unsigned region) {
    char why[200];
    auto f = [&](const char *what) {
      std::snprintf(why, sizeof why, "%s, ID %d, 0x%08" PRIx64 ": %s", ch, id, addr, what);
      fail(why);
    };
    if (size != 3) f("not eight bytes a beat");
    if (burst != 1) f("not INCR");
    if (user != 0xE0) f("AxUSER not SDRAM direct");
    if (cache != 2) f("AxCACHE not 0b0010");
    if (prot != 3) f("AxPROT not 0b011");
    if (lock || qos || region) f("lock, QoS or region not zero");
    if (addr % 8) f("not on eight bytes");
    if ((addr & 0xFFF) + 8ull * len > 4096) f("the burst runs across 4 KiB");
    if (id > 2) f("an ID no port of the share has");
    if (id == kMachine && !(at_main(addr) || (addr >= kDisplayBase && addr < kDisplayBase + 0x100000)))
      f("the machine's ID outside main memory and the frame buffer");
    if (id == kPack && !(addr >= kPackBase && addr < kPackBase + kPackBytes))
      f("the pack side's ID outside its region");
    if (id == kDisplay && (addr < kDisplayBase || addr >= kDisplayBase + 0x100000))
      f("the display's ID outside the frame buffer");
    if (id == kDisplay && std::strcmp(ch, "AW") == 0) f("a write with the display's ID");
  }

  // ------------------------------------------------------------- one clock
  void drive() {
    const bool in_reset = d->h2f_reset;
    const unsigned pct = ready_pct;
    d->f2s_awready = !in_reset && rng.chance(pct);
    d->f2s_wready = !in_reset && rng.chance(pct);
    d->f2s_arready = !in_reset && rng.chance(pct);
    d->f2s_bvalid = 0;
    d->f2s_bid = 0;
    d->f2s_bresp = 0;
    // Each ID's responses in order, and between IDs in any order: the
    // oldest due of an ID picked at random.
    b_pick = -1;
    if (!in_reset && rng.chance(pct)) {
      int cand[32], nc = 0;
      bool seen[32] = {};
      for (size_t k = 0; k < b_due.size(); ++k) {
        const int id = b_due[k].first & 31;
        if (seen[id]) continue;
        seen[id] = true;
        if (b_due[k].second <= t) cand[nc++] = static_cast<int>(k);
      }
      if (nc) {
        b_pick = cand[rng.below(nc)];
        d->f2s_bvalid = 1;
        d->f2s_bid = b_due[b_pick].first;
      }
    }
    d->f2s_rvalid = 0;
    d->f2s_rlast = 0;
    d->f2s_rdata = 0;
    d->f2s_rid = 0;
    d->f2s_rresp = 0;
    if (!in_reset && !ar_q.empty() && r_wait >= 0 && t >= r_wait && rng.chance(pct)) {
      Burst &b = ar_q.front();
      d->f2s_rdata = read_beat(b);
      d->f2s_rvalid = 1;
      d->f2s_rid = b.id;
      d->f2s_rlast = b.sent + 1 == b.len;
    }

    d->probe_run = t == pr_run_at;
    d->probe_stop = t == pr_stop_at;

    // The core's reset, as its state stands this clock.
    d->mach_rst = d->h2f_reset || core == kCoreReset;
    // The machine's port side, while the core is out of reset; nothing new
    // offered while it drains.
    const bool core_run = !d->mach_rst && core == kCoreRun;
    // The writes at the configuration's rate: BUSY back to back, the
    // others at a stream's rate (`write_interval`).
    if (core_run && !w_on && !to_write.empty() && d->w_free && inflight.size() < 16 &&
        t - last_offer >= write_interval(cfg) &&
        !((ar_on || rd_wait) && to_write.front().w / 8 == cur_line)) {
      cur = to_write.front();
      to_write.pop_front();
      w_on = true;
      last_offer = t;
      w_offer_t = t;
    }
    d->w_req = !d->mach_rst && w_on;
    d->w_bus = cur.w;
    d->w_word = cur.word;
    d->w_id = next_id & 15;
    if (core_run && !stopped && !ar_on && !rd_wait &&
        rng.chance(cfg == kHeld ? 3 : cfg == kFills ? 100 : others ? 2 : 15)) {
      const uint32_t line = rng.below(kWords / 8 - 1);
      // A line's read waits for every write to it, offered or taken.
      if (pending[line] == 0 && !(w_on && cur.w / 8 == line)) {
        cur_line = line;
        ar_on = true;
        fill_t = t;
      }
    }
    d->ar_req = !d->mach_rst && ar_on;
    d->ar_line = cur_line;

    // The pack side.
    d->p_awvalid = 0;
    d->p_wvalid = 0;
    d->p_arvalid = 0;
    d->p_bready = 1;
    d->p_rready = 1;
    d->p_awaddr = static_cast<uint32_t>(kPackBase + 128u * pk_pages[pk_wi < pk_n ? pk_wi : 0]);
    d->p_araddr = static_cast<uint32_t>(kPackBase + 128u * pk_pages[pk_ri < pk_n ? pk_ri : 0]);
    d->p_awlen = 15;
    d->p_arlen = 15;
    d->p_awsize = 3;
    d->p_arsize = 3;
    d->p_awburst = 1;
    d->p_arburst = 1;
    d->p_wstrb = 0xFF;
    d->p_wdata = (seed << 48) ^ (uint64_t(pk_pages[pk_wi < pk_n ? pk_wi : 0]) << 32) ^ (pk_beat * 0x01010101u) ^
                 uint64_t(pk_bursts << 8);
    d->p_wlast = pk_beat == 15;
    if (pk_state == 1) {
      d->p_awvalid = !pk_aw_done;
      d->p_wvalid = pk_beat < 16;
    } else if (pk_state == 3) {
      d->p_arvalid = pk_ri < pk_n;
    }
    // The display.
    d->d_arvalid = dp_state == 1 && dp_issued < dp_reads &&
                   dp_issued - dp_done < (dp_band ? kBandOutstanding : 1u);
    d->d_araddr = static_cast<uint32_t>(dp_addr_of(dp_issued));
    d->d_arlen = dp_band ? 0 : 15;
    d->d_arsize = 3;
    d->d_arburst = 1;
    d->d_rready = 1;
  }

  void take() {
    // ---- the bridge's address channels, before the edge.
    const bool aw_hs = d->f2s_awvalid && d->f2s_awready;
    const bool w_hs = d->f2s_wvalid && d->f2s_wready;
    const bool ar_hs = d->f2s_arvalid && d->f2s_arready;
    const bool b_hs = d->f2s_bvalid && d->f2s_bready;
    const bool r_hs = d->f2s_rvalid && d->f2s_rready;

    // A valid and its payload held until taken.
    const uint64_t aw_now = (uint64_t(d->f2s_awaddr) << 16) ^ (uint64_t(d->f2s_awlen) << 8) ^ d->f2s_awid;
    const uint64_t ar_now = (uint64_t(d->f2s_araddr) << 16) ^ (uint64_t(d->f2s_arlen) << 8) ^ d->f2s_arid;
    const uint64_t w_now = d->f2s_wdata ^ (uint64_t(d->f2s_wstrb) << 56) ^ (uint64_t(d->f2s_wlast) << 55);
    if (aw_held && (!d->f2s_awvalid || aw_now != aw_was)) fail("a write address withdrawn or changed before it was taken");
    if (ar_held && (!d->f2s_arvalid || ar_now != ar_was)) fail("a read address withdrawn or changed before it was taken");
    if (w_held && (!d->f2s_wvalid || w_now != w_was)) fail("a write beat withdrawn or changed before it was taken");
    if (!d->h2f_reset) {
      aw_held = d->f2s_awvalid && !aw_hs;
      ar_held = d->f2s_arvalid && !ar_hs;
      w_held = d->f2s_wvalid && !w_hs;
    }
    aw_was = aw_now;
    ar_was = ar_now;
    w_was = w_now;
    // A new address: a valid that did not stand unaccepted at the last edge.
    const bool aw_new = d->f2s_awvalid && !aw_prev;
    const bool ar_new = d->f2s_arvalid && !ar_prev;
    if (new_after >= 0 && t >= new_after && (aw_new || ar_new)) ++new_addresses_late;
    aw_prev = d->f2s_awvalid && !aw_hs;
    ar_prev = d->f2s_arvalid && !ar_hs;

    // The probe's own figures: an address taken, its answer.
    if (r_hs && d->f2s_rlast && d->f2s_rid == kMachine) {
      if (pr_rq.empty()) fail("the machine's last read beat with no read address taken");
      else {
        const uint64_t lat = static_cast<uint64_t>(t - pr_rq.front());
        pr_rq.pop_front();
        if (pr_counted(t)) {
          ++pr_rc;
          pr_rs += lat;
          pr_rm = std::max(pr_rm, lat);
        }
      }
    }
    if (b_hs && d->f2s_bid == kMachine) {
      if (pr_wq.empty()) fail("the machine's write response with no write address taken");
      else {
        const uint64_t lat = static_cast<uint64_t>(t - pr_wq.front());
        pr_wq.pop_front();
        if (pr_counted(t)) {
          ++pr_wc;
          pr_ws += lat;
          pr_wm = std::max(pr_wm, lat);
        }
      }
    }
    if (ar_hs && d->f2s_arid == kMachine) pr_rq.push_back(t);
    if (aw_hs && d->f2s_awid == kMachine) pr_wq.push_back(t);

    if (w_hs) {
      if (d->f2s_wuser != 0) fail("WUSER not zero");
      Beat w{d->f2s_wdata, d->f2s_wstrb, static_cast<bool>(d->f2s_wlast)};
      Burst *b = nullptr;
      for (auto &x : aw_q)
        if (x.sent < x.len) {
          b = &x;
          break;
        }
      if (b) land(*b, w);
      else w_early.push_back(w);
    }
    if (aw_hs) {
      check_address("AW", d->f2s_awid, d->f2s_awaddr, d->f2s_awlen + 1u, d->f2s_awsize, d->f2s_awburst,
                    d->f2s_awuser, d->f2s_awcache, d->f2s_awprot, d->f2s_awlock, d->f2s_awqos, d->f2s_awregion);
      aw_q.push_back({static_cast<int>(d->f2s_awid), d->f2s_awaddr, d->f2s_awlen + 1u, 0});
      // **ONE WRITE IN FLIGHT FOR THE PACK SIDE**, and the machine's list.
      const int id = d->f2s_awid & 31;
      if (id == kMachine) wr_at_most = std::max(wr_at_most, wr_at[id] + 1);
      if (++wr_at[id] > (id == kMachine ? kMachineWrites : 1)) {
        char why[120];
        std::snprintf(why, sizeof why, "ID %d has %ld writes unanswered at the bridge", id, wr_at[id]);
        fail(why);
      }
      while (!w_early.empty()) {
        Burst *b = nullptr;
        for (auto &x : aw_q)
          if (x.sent < x.len) {
            b = &x;
            break;
          }
        if (!b) break;
        land(*b, w_early.front());
        w_early.pop_front();
      }
    }
    while (!aw_q.empty() && aw_q.front().sent == aw_q.front().len) aw_q.pop_front();
    if (b_hs) {
      if (d->f2s_bid == kMachine) ++ans_w;
      --wr_at[d->f2s_bid & 31];
      b_due.erase(b_due.begin() + b_pick);
    }
    if (ar_hs) {
      check_address("AR", d->f2s_arid, d->f2s_araddr, d->f2s_arlen + 1u, d->f2s_arsize, d->f2s_arburst,
                    d->f2s_aruser, d->f2s_arcache, d->f2s_arprot, d->f2s_arlock, d->f2s_arqos, d->f2s_arregion);
      ar_q.push_back({static_cast<int>(d->f2s_arid), d->f2s_araddr, d->f2s_arlen + 1u, 0});
      if (ar_q.size() == 1) r_wait = t + 3 + rng.below(30);
    }
    if (r_hs) {
      Burst &b = ar_q.front();
      if (++b.sent == b.len) {
        if (b.id == kMachine) ++ans_r;
        ar_q.pop_front();
        r_wait = ar_q.empty() ? -1 : t + 1;
      }
    }
    // The tally's own reading of the same handshakes, a clock behind as the
    // port copies them.
    {
      const bool creq = (ar_hs && d->f2s_arid == kMachine) || (aw_hs && d->f2s_awid == kMachine);
      const bool cwrite = aw_hs && d->f2s_awid == kMachine;
      if (creq_q && !creq_qq) {
        if (cwrite_q) ++ask_w;
        else ++ask_r;
      }
      creq_qq = creq_q;
      creq_q = creq;
      cwrite_q = cwrite;
    }

    // ---- the machine's port side.
    if (w_on && d->w_req && d->w_taken) {
      for (int k = 0; k < 5; ++k) {
        want[5ull * cur.w + k] = static_cast<uint8_t>(cur.word >> (8 * k));
        unsure[5ull * cur.w + k] = 0;
      }
      ++pending[cur.w / 8];
      const uint64_t a = kBase + 5ull * cur.w;
      const bool split = (a % 8) >= 4 && ((a / 8 + 1) % 512) == 0;
      if ((a % 8) >= 4) ++two_beat;
      if (split) ++splits;
      inflight.push_back({cur.w, cur.w / 8, split});
      ++next_id;
      w_on = false;
      ++writes;
      // The write's occupancy: from its offer to its accept, both clocks.
      const long occ = t - w_offer_t + 1;
      occ_sum += occ;
      occ_max = std::max(occ_max, occ);
      if (first_taken < 0) first_taken = t;
      last_taken = t;
    }
    if (!d->mach_rst && d->b_done) {
      if (inflight.empty()) {
        fail("a write answered that was not taken");
      } else {
        if (d->b_id != (ans_id & 15)) fail("a write answered out of order");
        --pending[inflight.front().line];
        inflight.pop_front();
        ++ans_id;
      }
    }
    if (ar_on && d->ar_req && d->ar_taken) {
      ar_on = false;
      rd_wait = true;
    }
    if (rd_wait && !d->mach_rst && d->rd_last) {
      uint8_t got[40];
      std::memcpy(got, &d->rd_data, 40);
      if (std::memcmp(got, &mem[40ull * cur_line], 40) != 0) {
        int k = 0;
        while (k < 40 && got[k] == mem[40ull * cur_line + k]) ++k;
        char why[200];
        std::snprintf(why, sizeof why, "a line read is not the bridge's line: line %u, byte %d first, the last reset "
                      "at clock %ld", cur_line, k, last_reset);
        fail(why);
      }
      rd_wait = false;
      ++reads;
      fill_sum += t - fill_t;
      fill_max = std::max(fill_max, t - fill_t);
      ++fills;
    }

    // ---- the core going into reset: what the drain promises.
    if (d->mach_rst && !mach_rst_prev) {
      ++resets;
      last_reset = t;
      for (auto &x : aw_q)
        if (x.id == kMachine) fail("the core reset with a write burst of its own at the bridge");
      for (auto &x : ar_q)
        if (x.id == kMachine && cfg != kHps) fail("the core reset with a read of its own at the bridge");
      for (auto &x : b_due)
        if (x.first == kMachine && cfg != kHps) fail("the core reset with a write of its own unanswered at the bridge");
      if (!w_early.empty() && cfg != kHps) fail("the core reset with a write beat at the bridge and no address");
      if (rd_wait && cfg != kHps) fail("the core reset with a line fill it took still to come");
      if (!inflight.empty() && cfg != kHps) fail("the core reset with a write of its own unanswered");
      // What the reset leaves: an unanswered write's bytes may or may not
      // be memory's; the next word written there settles them.
      for (auto &x : inflight) {
        --pending[x.line];
        for (int k = 0; k < 5; ++k) unsure[5ull * x.w + k] = 1;
      }
      inflight.clear();
      // The core's port numbers its writes from zero again, as the master
      // answers them from zero.
      ans_id = next_id = 0;
      if (w_on) to_write.push_front(cur);
      w_on = false;
      ar_on = false;
      rd_wait = false;
    }
    if (!d->mach_rst && mach_rst_prev) released = t;
    mach_rst_prev = d->mach_rst;

    // ---- the core's reset rule, at the edge.
    const bool req = tb_req || !d->may_start;
    if (d->h2f_reset) {
      core = req ? kCoreReset : kCoreRun;
      core_count = 0;
    } else if (core == kCoreRun) {
      if (req) {
        core = kCoreDrain;
        drain_from = t;
      }
    } else if (core == kCoreDrain) {
      if (!w_on && !ar_on && !rd_wait && inflight.empty()) {
        core = kCoreReset;
        core_count = 0;
        longest_drain = std::max(longest_drain, t - drain_from);
      } else if (t - drain_from > kDrainBound) {
        fail("the master's drain did not end: the share does not let it finish");
        core = kCoreReset;
      }
    } else {
      if (core_count < 64) ++core_count;
      else if (!req) core = kCoreRun;
    }

    // ---- the pack side.
    if (others) {
      if (!(pk_state == 1 || pk_state == 2) && d->p_bvalid) fail("a write response to the pack side, which has no write out");
      if (d->p_bvalid && pk_bs >= pk_wi) fail("a write response to the pack side before its write was taken");
      if (pk_state != 3 && d->p_rvalid) fail("read data to the pack side, which has no read out");
      if (d->p_rvalid && pk_rj >= pk_ri) fail("read data to the pack side before its address was taken");
      if (d->d_rvalid && dp_q.empty()) fail("read data to the display, which has no read out");
      const bool p_aw = d->p_awvalid && d->p_awready;
      const bool p_w = d->p_wvalid && d->p_wready;
      if ((pk_state == 1 || pk_state == 2) && d->p_bvalid && pk_bs < pk_wi) {
        pk_worst = std::max(pk_worst, t - pk_wstart[pk_bs]);
        ++pk_bs;
      }
      if (pk_state == 0) {
        if (pk_gap > 0) --pk_gap;
        else {
          pk_state = 1;
          pk_n = rng.chance(50) ? 2 : 1;
          pk_pages[0] = rng.below(kPackBytes / 128);
          pk_pages[1] = (pk_pages[0] + 1 + rng.below(kPackBytes / 128 - 1)) % (kPackBytes / 128);
          pk_wi = pk_bs = pk_ri = pk_rj = 0;
          pk_beat = 0;
          pk_aw_done = false;
          pk_wstart[0] = t + 1;
        }
      } else if (pk_state == 1) {
        // The address and the beats each taken in their own time, as a
        // bridge may take a write's data before its address.
        if (p_aw) pk_aw_done = true;
        if (p_w) {
          for (int k = 0; k < 8; ++k)
            pk_expect[128 * pk_pages[pk_wi] + 8 * pk_beat + k] = static_cast<uint8_t>(d->p_wdata >> (8 * k));
          ++pk_beat;
        }
        if (pk_aw_done && pk_beat == 16) {
          // The next write offered at once, before this one's response.
          ++pk_wi;
          pk_beat = 0;
          pk_aw_done = false;
          if (pk_wi < pk_n) pk_wstart[pk_wi] = t + 1;
          else pk_state = 2;
        }
      }
      if (pk_state == 2 && pk_bs == pk_n) {
        pk_state = 3;
        pk_rbeat = 0;
        pk_rstart[0] = t + 1;
      } else if (pk_state == 3) {
        if (d->p_arvalid && d->p_arready) {
          ++pk_ri;
          if (pk_ri < pk_n) pk_rstart[pk_ri] = t + 1;
        }
        if (d->p_rvalid && pk_rj < pk_ri) {
          const unsigned page = pk_pages[pk_rj];
          uint64_t want_beat = 0;
          for (int k = 0; k < 8; ++k) want_beat |= uint64_t(pk_expect[128 * page + 8 * pk_rbeat + k]) << (8 * k);
          if (d->p_rdata != want_beat) fail("the pack side read back a beat that is not the one it wrote");
          if (d->p_rlast != (pk_rbeat == 15)) fail("the pack side's RLAST not on its burst's last beat");
          if (++pk_rbeat == 16) {
            pk_worst = std::max(pk_worst, t - pk_rstart[pk_rj]);
            pk_rbeat = 0;
            ++pk_bursts;
            if (++pk_rj == pk_n) {
              pk_state = 0;
              pk_gap = cfg == kFlood ? 0 : rng.below(37);
            }
          }
        }
      }
      // ---- the display.
      if (d->d_arvalid && dp_since < 0) dp_since = t;
      if (d->d_arvalid && d->d_arready) {
        dp_q.push_back({dp_addr_of(dp_issued), dp_band ? 1u : 16u, dp_since});
        dp_since = -1;
        ++dp_issued;
      }
      if (d->d_rvalid && !dp_q.empty()) {
        DpRead &h = dp_q.front();
        if (d->d_rdata != DisplayBeat(h.addr + 8ull * dp_beat)) fail("the display was given a beat not its own");
        if (d->d_rlast != (dp_beat + 1 == h.len)) fail("the display's RLAST not on its burst's last beat");
        if (++dp_beat == h.len) {
          dp_worst = std::max(dp_worst, t - h.start);
          dp_q.pop_front();
          dp_beat = 0;
          ++dp_done;
          ++dp_bursts;
          if (dp_done == dp_reads) {
            if (dp_band) {
              dp_band_worst = std::max(dp_band_worst, t - dp_job_start);
              ++dp_bands;
            }
            dp_state = 0;
            dp_gap = cfg == kFlood ? 0 : rng.below(23);
          }
        }
      }
      if (dp_state == 0) {
        if (dp_gap > 0) --dp_gap;
        else {
          dp_state = 1;
          dp_band = rng.chance(50);
          dp_reads = dp_band ? kBandReads : 1;
          dp_base = dp_band ? 8ull * rng.below(12) : 128ull * rng.below(1024);
          dp_issued = dp_done = 0;
          dp_beat = 0;
          dp_job_start = t + 1;
        }
      }
    } else {
      if (d->p_bvalid || d->p_rvalid || d->d_rvalid) fail("an answer to a master that asked nothing");
    }
  }

  std::vector<uint8_t> pk_expect = std::vector<uint8_t>(kPackBytes, 0);

  void tick() {
    drive();
    d->clk = 0;
    d->eval();
    take();
    d->clk = 1;
    d->eval();
    ++t;
  }

  bool quiet() {
    return to_write.empty() && !w_on && inflight.empty() && !ar_on && !rd_wait && b_due.empty() &&
           aw_q.empty() && ar_q.empty() && w_early.empty();
  }

  int go(long ops) {
    for (long k = 0; k < ops; ++k) {
      uint32_t w = rng.below(kWords - 1);
      if (rng.chance(10)) w = static_cast<uint32_t>((4096u * (1 + rng.below(38)) - 4) / 5);
      to_write.push_back({w, rng.next() & 0xFFFFFFFFFFull});
    }
    // The fabric's reset, the processor in reset, the port shut.
    d->rst = 1;
    d->h2f_reset = 1;
    d->gp_open = 0;
    d->gp_half = 0;
    d->warm_req_n = 1;
    tb_req = false;
    d->mach_rst = 1;   // the core powers up in its reset
    for (int k = 0; k < 4; ++k) {
      d->clk = 0;
      d->eval();
      d->clk = 1;
      d->eval();
    }
    d->rst = 0;
    const long open_at = cfg == kOpen ? 3000 : 100;
    const long shut_at = 2000, shut_for = 3000;
    const long quiet_at = 2500, quiet_for = 2000;
    const long hps_at = 2500, hps_for = 1000, hps_reopen = 3000;
    const long limit = ops * 400 + 20000;
    // The probe started with the traffic under way.
    pr_run_at = open_at + 700;
    bool any_before_open = false;
    long acked_at = -1, req_seen = -1;
    long shut_quiet_writes = 0;
    while (t < limit && bad == 0) {
      // The processor and software.
      if (t == 50) d->h2f_reset = 0;
      if (t == open_at) d->gp_open = 1;
      if (cfg == kHeld) {
        if (t == shut_at) {
          d->gp_open = 0;
          new_after = shut_at + kHeldSlack;
        }
        if (t == shut_at + shut_for) {
          d->gp_open = 1;
          new_after = -1;
        }
        if (t > shut_at + kHeldSlack && t < shut_at + shut_for) {
          if (!to_write.empty() || w_on) ++queued_while_shut;
          if (d->w_taken && d->w_req) ++shut_quiet_writes;
          if (d->mach_rst) fail("the machine reset while the port is shut");
        }
      }
      tb_req = cfg == kReset && t > 1000 && t % 1777 == 0 && t < limit / 2;
      if (cfg == kHandshake) {
        if (t == quiet_at) {
          d->warm_req_n = 0;
          new_after = quiet_at + kHeldSlack;
          req_seen = quiet_at;
        }
        if (t == quiet_at + quiet_for) {
          d->warm_req_n = 1;
          new_after = -1;
        }
        if (req_seen >= 0 && !d->warm_ack_n && acked_at < 0) {
          acked_at = t;
          if (!aw_q.empty() || !ar_q.empty() || !b_due.empty() || !w_early.empty())
            fail("the fabric acknowledged quiet with transactions outstanding at the bridge");
        }
        if (t > quiet_at + quiet_for + 10 && !d->warm_ack_n) fail("the acknowledgment stands after the request went");
      }
      if (cfg == kHps) {
        if (t == hps_at) {
          d->h2f_reset = 1;
          d->gp_open = 0;
          bridge_reset();
        }
        if (t == hps_at + hps_for) d->h2f_reset = 0;
        if (t == hps_at + hps_for + hps_reopen) d->gp_open = 1;
        if (d->h2f_reset) bridge_reset();
      }
      if (d->live && live_rise < 0) live_rise = t;
      if (t < open_at && (d->f2s_awvalid || d->f2s_arvalid || d->f2s_wvalid)) any_before_open = true;
      if (t < open_at && !d->mach_rst) fail("the machine out of reset before its port has been live");
      // The probe's first run stopped and read, then a second RUN.
      if (pr_phase == 0 && t == pr_run_at + 3000) pr_stop_at = t;
      if (pr_phase == 0 && pr_stop_at >= 0 && t == pr_stop_at + 4) {
        probe_check("after the first run");
        pr_rc1 = pr_rc;
        pr_wc1 = pr_wc;
        pr_rc = pr_rs = pr_rm = pr_wc = pr_ws = pr_wm = 0;
        pr_run_at = t;
        pr_stop_at = -1;
        pr_phase = 1;
      }
      tick();
      if (to_write.empty() && quiet() && t > 9000 && !d->mach_rst) break;
    }
    if (bad == 0 && t >= limit) {
      char why[240];
      std::snprintf(why, sizeof why,
                    "the run did not end: %zu writes still to offer, %zu unanswered, %zu addresses owed beats, "
                    "%zu beats with no address, %zu responses owed, %zu reads owed",
                    to_write.size(), inflight.size(), aw_q.size(), w_early.size(), b_due.size(), ar_q.size());
      fail(why);
    }
    if (any_before_open) fail("a transaction reached the bridge before software opened the port");
    if (bad == 0 && (live_rise < 0 || released < 0)) fail("the port never came live, or the machine never ran");
    if (bad == 0 && cfg == kOpen && released - live_rise > kReleaseBound) {
      char why[120];
      std::snprintf(why, sizeof why, "the machine let go %ld clocks after the port came live, wanting %ld at most",
                    released - live_rise, kReleaseBound);
      fail(why);
    }
    if (bad == 0 && cfg == kOpen && released < live_rise) fail("the machine let go before the port came live");
    if (new_addresses_late) {
      char why[120];
      std::snprintf(why, sizeof why, "%ld addresses put to the bridge after the port held its grants",
                    new_addresses_late);
      fail(why);
    }
    if (bad == 0 && cfg == kHeld && queued_while_shut == 0) fail("no write stood queued while the port was shut");
    if (bad == 0 && cfg == kHeld && shut_quiet_writes) fail("a write was taken while the port was shut");
    if (bad == 0 && cfg == kReset && resets < 3) fail("the machine was reset fewer than three times");
    if (bad == 0 && cfg == kHandshake && acked_at < 0) fail("the fabric never acknowledged the request for quiet");
    // What a master still waits for at the end counts as waited.
    if (others) {
      if (dp_since >= 0) dp_worst = std::max(dp_worst, t - dp_since);
      if (!dp_q.empty()) dp_worst = std::max(dp_worst, t - dp_q.front().start);
      if (pk_state == 1 || pk_state == 2) pk_worst = std::max(pk_worst, t - pk_wstart[pk_bs < pk_n ? pk_bs : 0]);
      if (pk_state == 3) pk_worst = std::max(pk_worst, t - pk_rstart[pk_rj < pk_n ? pk_rj : 0]);
    }
    char meas[700];
    std::snprintf(meas, sizeof meas,
                  "machine: %ld writes, %.2f clocks from offer to accept (most %ld), %.2f clocks a write; %ld fills, "
                  "%.1f clocks (most %ld); display: the longest wait %ld, a band of %u reads %ld at most (%ld bands); "
                  "pack: the longest wait %ld; the machine's writes in flight at most %ld; the probe: %" PRIu64 " reads, %.1f clocks (most %" PRIu64 "), %" PRIu64
                  " writes, %.1f clocks (most %" PRIu64 ")",
                  writes, writes ? double(occ_sum) / writes : 0.0, occ_max,
                  writes > 1 ? double(last_taken - first_taken) / (writes - 1) : 0.0, fills,
                  fills ? double(fill_sum) / fills : 0.0, fill_max, dp_worst, kBandReads, dp_band_worst, dp_bands,
                  pk_worst, wr_at_most, pr_rc, pr_rc ? double(pr_rs) / pr_rc : 0.0, pr_rm, pr_wc, pr_wc ? double(pr_ws) / pr_wc : 0.0,
                  pr_wm);
    // **NEITHER OTHER MASTER STARVES** beside the machine's streams: the
    // display's reads within its line budget, the pack side's bursts within
    // its bound.  HANDSHAKE shuts the port for 2,000 clocks on purpose.
    if (others && cfg != kHandshake) {
      if (dp_worst > kLineBudget) {
        char why[160];
        std::snprintf(why, sizeof why, "the display waited %ld clocks for a read, past its line budget of %ld",
                      dp_worst, kLineBudget);
        fail(why);
      }
      if (occ_max > kMachineBound || fill_max > kMachineBound) {
        char why[160];
        std::snprintf(why, sizeof why, "the machine waited %ld clocks for a write and %ld for a fill, past its bound of %ld",
                      occ_max, fill_max, kMachineBound);
        fail(why);
      }
      if (dp_band_worst > kBandBudget) {
        char why[160];
        std::snprintf(why, sizeof why, "a band of %u of the display's reads took %ld clocks, past its budget of %ld",
                      kBandReads, dp_band_worst, kBandBudget);
        fail(why);
      }
      if (pk_worst > kPackBudget) {
        char why[160];
        std::snprintf(why, sizeof why, "the pack side waited %ld clocks for a burst, past its bound of %ld", pk_worst,
                      kPackBudget);
        fail(why);
      }
    }
    // **THE MACHINE'S WRITES ARE POSTED THROUGH THE SHARE**: back to back,
    // several are at the bridge unanswered at once, not one at a time.
    if (cfg == kBusy && wr_at_most < 4) {
      char why[160];
      std::snprintf(why, sizeof why, "the machine had at most %ld writes unanswered at the bridge, posting back to back",
                    wr_at_most);
      fail(why);
    }
    if (bad == 0 && others && (pk_bursts < 10 || dp_bursts < 10)) {
      char why[160];
      std::snprintf(why, sizeof why, "the pack side ran %ld bursts and the display %ld, beside %ld writes and %ld reads",
                    pk_bursts, dp_bursts, writes, reads);
      fail(why);
    }
    // Every byte written is memory's, but those a reset left unsettled.
    if (bad == 0) {
      size_t diff = 0;
      for (size_t i = 0; i < kBytes; ++i)
        if (!unsure[i] && mem[i] != want[i]) ++diff;
      if (diff) {
        char why[120];
        std::snprintf(why, sizeof why, "%zu bytes of main memory are not the bytes written", diff);
        fail(why);
      }
    }
    // **THE PROBE**, stopped, against the same handshakes timed here.  The
    // port side asks nothing more from here on, so that no answer of its
    // straddles the probe's reading or the tally's.
    if (bad == 0) {
      stopped = true;
      pr_stop_at = t;
      for (int k = 0; k < 4; ++k) tick();
      probe_check("at the end");
      if (bad == 0 && (pr_rc + pr_rc1 == 0 || pr_wc + pr_wc1 == 0)) fail("the probe timed no read or no write");
    }
    // The tally, in both halves, by the bridge's handshakes.
    if (bad == 0 && cfg != kHps) {
      stopped = true;
      auto settle = [&](int half) {
        d->gp_half = half;
        for (int k = 0; k < 8; ++k) tick();
        return static_cast<uint32_t>(d->gp_in);
      };
      const uint32_t lo = settle(0), hi = settle(1);
      auto sat = [](long n) { return static_cast<uint32_t>(n > 32767 ? 32767 : n); };
      const uint32_t want_lo = 0x8000u | sat(ans_r) | (sat(ans_w) << 16);
      const uint32_t want_hi = 0x8000u | sat(ask_r) | (sat(ask_w) << 16);
      if (lo != want_lo || hi != want_hi) {
        char why[200];
        std::snprintf(why, sizeof why, "the tally reads %08x and %08x, and the bridge answered %08x and was asked %08x",
                      lo, hi, want_lo, want_hi);
        fail(why);
      }
    }
    if (bad) {
      std::fprintf(stderr, "FAIL: seed %" PRIu64 ", %s, readies %u%%: %ld problems; %s\n", seed, config_name(cfg),
                   ready_pct, bad, meas);
      return 1;
    }
    std::printf("ok: seed %" PRIu64 ", %-9s readies %3u%%: %ld writes (%ld of two beats, %ld split at 4 KiB), %ld "
                "line reads, %ld resets (the longest drain %ld clocks), live at %ld, let go at %ld; pack %ld bursts, "
                "display %ld; %ld clocks; %s\n",
                seed, config_name(cfg), ready_pct, writes, two_beat, splits, reads, resets, longest_drain, live_rise,
                released, pk_bursts, dp_bursts, t, meas);
    return 0;
  }
};

long ops_for(Config c) {
  switch (c) {
    case kBusy: return 3000;
    case kZero: return 3000;
    case kFlood: return 3000;
    case kFills: return 600;
    default: return 1500;
  }
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  int bad = 0;
  // One run by hand: `<configuration 0-5> <seed> <readies>`.
  if (argc == 4) {
    Run run(std::strtoull(argv[2], nullptr, 10), static_cast<Config>(std::atoi(argv[1])),
            static_cast<unsigned>(std::atoi(argv[3])));
    return run.go(ops_for(static_cast<Config>(std::atoi(argv[1]))));
  }
  for (Config c : {kOpen, kHeld, kReset, kHandshake, kHps, kBusy, kZero, kBitblt, kFills, kFlood})
    for (uint64_t seed = 1; seed <= 3; ++seed)
      for (unsigned r : {100u, 40u}) {
        Run run(seed, c, r);
        bad += run.go(ops_for(c));
      }
  return bad ? 1 : 0;
}
