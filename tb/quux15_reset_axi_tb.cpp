// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **A RESET ASKED FOR WHILE THE MEMORY PORT IS BUSY**, on revision 15:
// `rtl/machine/quux15_core.sv`, whose 64-bit master (`quux15_axi_master.sv`)
// sits inside the core's port, reset as a board's top level resets it, against
// a memory port that a machine reset does not reach, as a board's processing
// system is not reached by BTN1, KEY1 or the console's RESET key.  The core
// is built in `tb/quux15_reset_harness.sv`, behind one board's adapter
// (`QUUX15_RESET_BOARD`: 0 the core's own port, 1 the Arty Z7-20's AXI3
// shim, 2 the Kria KR260's narrow bursts on 128 bits) and with the console
// face.  The rule held (A15b.5's Drains and its board-reset clarification):
// a reset the board asks for is latched; the port grants nothing new; every
// write it has queued or in flight lands and every read it has asked for
// comes in; then the core is reset.  Measured, not argued:
//
//   - **quiet at delivery**: in the clock the core's reset rises after a
//     request, no VALID is up and this file's port owes and is owed nothing
//     (no address without its beats, no R or B to come);
//   - **land-all**: every write the port granted since the last reset is in
//     this file's memory as the reset rises (muir's `Port::drain_now`);
//   - **coherence**: at the reset's release every valid way of the cache
//     equals memory, word for word;
//   - what reaches the master after the reset that belongs to a transaction
//     from before it: an R beat ("stray"), split by whether the master was
//     idle (dropped) or in a new fill (taken as the new line's); a B
//     ("late"); a W beat paired with an address of another generation
//     ("misdirected"), a WLAST that disagrees with its burst's length;
//   - a VALID withdrawn without its READY (an AXI rule broken);
//   - each line the master completes, its bytes held to memory as the line's
//     address found it ("fill wrong");
//   - after the program has run again from its start: whether it reaches its
//     stop (a hang), whether the port drains, M, and main memory byte for
//     byte against the same program run with no reset.
//
//   V<top> <trace> <run> [options]
//
// The run's memories are loaded as `tb/quux15_core_tb.cpp` loads them (its
// `# image` lines); the program is in the control store from 0, the PROM's
// first word a jump to 0, so that a reset starts it again from its first
// word.  The port is this file's own, one ID a channel, answered in order:
//
//   --lat-r N, --lat-b N, --r-gap N, --aw-delay N, --w-delay N, --ar-delay N
//                 clocks from a read address to its first beat, from a
//                 write's last beat to its B, between beats; READY rises
//                 once VALID has been up N clocks
//   --reset-at T  the request (BTN1's or KEY1's) up for clocks T .. T+len-1
//   --reset-len N (64)
//   --bounce S    the request as a bouncing button from T: twelve pulses of
//                 1 to 10 clocks, 1 to 1,000 apart, seeded by S
//   --face-at T   the request as the console face's RESET key, written at T
//                 on the face's page: its answer's clock and word 6 after it
//   --hard-at T --hard-len N
//                 the hard reset (the port's own, the clock's lock) at T for
//                 N clocks (8); it reaches this file's port too, which forgets
//                 what it had of the master's transactions, as the processing
//                 system's port does on its own reset
//   --dead-at T   from T the port answers nothing: no READY, no R, no B,
//                 until a hard reset revives it.  The request is then
//                 expected to be cut at the core's bound, the core held in
//                 reset until the hard reset, `rst_cut` set and kept, and the
//                 face's write answered at its bound
//   --errhalt-at T  an error halt at T (the core's `errhalt` set), the
//                 request after it: an error-halted machine is reset as any
//   --halt-at T   RUN cleared at T, as the console clears it: the request
//                 during the console's halt or its drain
//   --sweep-after-reset  -RESET's sweep of the TLB taken as done after the
//                 reset too, so that the program asks for memory within
//                 clocks of it: the check runs so, the sweep carrying no safety
//   --amem OLD=NEW, --amem-after OLD=NEW
//                 an A-memory image word replaced, before the run or at the
//                 reset's release (a program's address moved)
//   --sweep read|write|write-span --target K [--step S]
//                 run once with no reset, find the K-th line read (write;
//                 the first K writes), and run again with the request at
//                 every clock (every S-th) from its first VALID to its last
//                 beat (B) and one after; a line per position, a summary line
//   --resume-at P the read-back program (`resetback`, golden
//                 `quux15_memside.rs`): at the reset the PROM's jump to 0
//                 becomes a jump to P, its phase 2, which reads back, without
//                 writing them again, the 32 words phase 1 wrote.  `P` is the
//                 trace's `# resume` line when not given.  Counted: `lost`,
//                 granted words memory does not hold at the end; `w1c`/`w1u`,
//                 pass 1's wrong copies of the cached lines' words and of the
//                 uncached ones; `w2`, pass 2's of the cached lines' after
//                 their eviction; `corrupt`, other words not as expected
//   --fault extra-r|extra-r-idle|extra-b|ghost-aw|drop-b|drop-write
//                 the port planted wrong, to show what this file counts
//   --first       a sweep stops at its first position that misbehaves (a
//                 mutation run, where one is enough)
//   --sweep-hard  a sweep moves the hard reset (`--hard-at`) and asks for no
//                 reset: **AFTER A HARD RESET THE CACHE MUST HOLD NOTHING
//                 MEMORY MAY NOT** --- the queue and the in-flight list are
//                 dropped with the port's other side, so the cache's valid
//                 bits are cleared with them.  Held: the cache against memory
//                 at the release, and the read-back program reading each word
//                 alike from the cache and from memory, the word as written
//                 or as it was (`incons`)
//   --clear-check every valid bit of both ways set just before the hard
//                 reset (`--hard-at`); at its release none may read set, at
//                 the core's cache size (`QUUX15_RESET_SETS`)
//
// A position "misbehaves" when any count is not zero, when the program does
// not reach its stop or the port does not drain, when M is not what the run
// with no reset left, or when main memory differs from it.  Beats and Bs
// that arrive while the core is in reset are counted apart and reported:
// after a drained request there are none; after a hard reset they are the
// forgotten transactions' and this file's port drops them with the reset.
//
// `OLD_RESET` (the harness's) builds the core as revision 15 had it before
// the request: one reset, the request straight onto it; the same counts
// then show what the request fixes.

#include <cinttypes>
#include <map>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#include "verilated.h"
#include "Vquux15_reset_harness.h"
#include "Vquux15_reset_harness___024root.h"
#ifndef QUUX15_RESET_SETS
#define QUUX15_RESET_SETS 4096
#endif
// The valid maps' class, by the sets (Verilator names it by `ENTRIES` in hex).
#if QUUX15_RESET_SETS == 4096
#include "Vquux15_reset_harness_quux15_validmap__E1000_R3.h"
#define QUUX15_VMAP Vquux15_reset_harness_quux15_validmap__E1000_R3
#elif QUUX15_RESET_SETS == 1024
#include "Vquux15_reset_harness_quux15_validmap__E400_R3.h"
#define QUUX15_VMAP Vquux15_reset_harness_quux15_validmap__E400_R3
#elif QUUX15_RESET_SETS == 256
#include "Vquux15_reset_harness_quux15_validmap__E100_R3.h"
#define QUUX15_VMAP Vquux15_reset_harness_quux15_validmap__E100_R3
#else
#error "QUUX15_RESET_SETS: 256, 1024 or 4096"
#endif

#ifndef QUUX15_RESET_BOARD
#define QUUX15_RESET_BOARD 0
#endif

// The core's own names inside the harness.
#define C(x) quux15_reset_harness__DOT__u_core__DOT__##x
#define CP(x) __PVT__quux15_reset_harness__DOT__u_core__DOT__##x

// The valid maps' 64 columns (`quux15_validmap.sv`'s `g_col[c].m`).
#define VCOL(m, c, k) c[k] = &(m)->__PVT__g_col__BRA__##k##__KET____DOT__m
#define VCOLS(m, c) do { \
    VCOL(m, c, 0); VCOL(m, c, 1); VCOL(m, c, 2); VCOL(m, c, 3); VCOL(m, c, 4); VCOL(m, c, 5); VCOL(m, c, 6); VCOL(m, c, 7); \
    VCOL(m, c, 8); VCOL(m, c, 9); VCOL(m, c, 10); VCOL(m, c, 11); VCOL(m, c, 12); VCOL(m, c, 13); VCOL(m, c, 14); VCOL(m, c, 15); \
    VCOL(m, c, 16); VCOL(m, c, 17); VCOL(m, c, 18); VCOL(m, c, 19); VCOL(m, c, 20); VCOL(m, c, 21); VCOL(m, c, 22); VCOL(m, c, 23); \
    VCOL(m, c, 24); VCOL(m, c, 25); VCOL(m, c, 26); VCOL(m, c, 27); VCOL(m, c, 28); VCOL(m, c, 29); VCOL(m, c, 30); VCOL(m, c, 31); \
    VCOL(m, c, 32); VCOL(m, c, 33); VCOL(m, c, 34); VCOL(m, c, 35); VCOL(m, c, 36); VCOL(m, c, 37); VCOL(m, c, 38); VCOL(m, c, 39); \
    VCOL(m, c, 40); VCOL(m, c, 41); VCOL(m, c, 42); VCOL(m, c, 43); VCOL(m, c, 44); VCOL(m, c, 45); VCOL(m, c, 46); VCOL(m, c, 47); \
    VCOL(m, c, 48); VCOL(m, c, 49); VCOL(m, c, 50); VCOL(m, c, 51); VCOL(m, c, 52); VCOL(m, c, 53); VCOL(m, c, 54); VCOL(m, c, 55); \
    VCOL(m, c, 56); VCOL(m, c, 57); VCOL(m, c, 58); VCOL(m, c, 59); VCOL(m, c, 60); VCOL(m, c, 61); VCOL(m, c, 62); VCOL(m, c, 63); \
  } while (0)

namespace {

using Top = Vquux15_reset_harness;
constexpr int kBoard = QUUX15_RESET_BOARD;
// The port's beat: 16 bytes on the Kria's, 8 on the others; every burst's
// beats are eight bytes apart (AxSIZE 3), in the half bit 3 selects on 16.
constexpr int kBus = kBoard == 2 ? 16 : 8;
// The cache's sets, the core's `CACHE_WORDS` / 16, and the bits a set takes.
constexpr int kSets = QUUX15_RESET_SETS;
constexpr int kSetBits = kSets == 4096 ? 12 : kSets == 1024 ? 10 : 8;
constexpr int kGroups = kSets / 64;

constexpr uint64_t kMainWords = uint64_t(32) << 16;
constexpr uint64_t kDisplayBase = 0x0A000000ull;
constexpr uint32_t kStop = 01000;  // octal 1000, the run's stop
// The core's bound on a drain (`RESET_BOUND`) and the face's on its answer
// (`ANSWER_T`), the defaults the boards build.
constexpr long kCoreBound = 65536;
constexpr long kAnswerBound = 131072;
constexpr uint32_t kResetKey = 0x52534554u;
// A transaction's tag is the generation of the master that made it: the
// resets released before it was taken.  The planted faults' are of none.
constexpr int kTagLost = -1;

struct Image {
  std::string memory;
  uint64_t address, word;
};
struct Run {
  std::string name;
  std::vector<Image> images;
  uint64_t period = 20, rtc = 0;
  bool skip_sweep = false;
  long resume = -1;
};

bool read_run(const char *path, const std::string &want, Run &run) {
  std::FILE *f = std::fopen(path, "r");
  if (!f) return false;
  char line[512];
  bool in = false, found = false;
  // A trace of one run has no `# run` line: it is that run, by any name.
  bool runs = false;
  while (std::fgets(line, sizeof line, f))
    if (std::strncmp(line, "# run ", 6) == 0) runs = true;
  std::rewind(f);
  if (!runs) {
    in = found = true;
    run.name = want;
  }
  while (std::fgets(line, sizeof line, f)) {
    if (std::strncmp(line, "# run ", 6) == 0) {
      std::string n(line + 6);
      while (!n.empty() && (n.back() == '\n' || n.back() == '\r')) n.pop_back();
      if (in) break;
      in = n == want;
      if (in) {
        found = true;
        run.name = n;
      }
      continue;
    }
    if (!in || line[0] != '#') continue;
    char mem[32];
    uint64_t a, w;
    if (std::sscanf(line, "# image %31s %" SCNx64 " %" SCNx64, mem, &a, &w) == 3) {
      run.images.push_back({mem, a, w});
    } else if (std::sscanf(line, "# period %" SCNx64, &a) == 1) {
      run.period = a;
    } else if (std::sscanf(line, "# rtc %" SCNx64, &a) == 1) {
      run.rtc = a;
    } else if (std::sscanf(line, "# resume %" SCNx64, &a) == 1) {
      run.resume = long(a);
    } else if (std::strncmp(line, "# sweep skipped", 15) == 0) {
      run.skip_sweep = true;
    }
  }
  std::fclose(f);
  return found;
}

struct Cfg {
  int lat_r = 20, lat_b = 13, r_gap = 0, aw_delay = 0, w_delay = 0, ar_delay = 0;
  long reset_at = -1;
  int reset_len = 64;
  long bounce = -1;  // the train's seed, or none
  long face_at = -1, hard_at = -1, dead_at = -1, errhalt_at = -1, halt_at = -1;
  int hard_len = 8;
  bool sweep_after = false, clear_check = false;
  std::string fault;
  std::vector<std::pair<uint64_t, uint64_t>> amem, amem_after;
  long budget = 200000;  // clocks after the last release, or after the start
  bool verbose = false;
  long resume_at = -1;  // the read-back program's phase 2, or none
  bool any_request() const { return reset_at >= 0 || face_at >= 0; }
};

// What one run saw.
struct Counts {
  long stray_r_idle = 0, stray_r_fill = 0, r_in_reset = 0;
  long late_b = 0, b_in_reset = 0;
  long misdirected_w = 0, wlast_bad = 0;
  long drop_ar = 0, drop_aw = 0, drop_w = 0;
  long fill_wrong = 0;
  long orphan_aw = 0, orphan_w = 0, ar_unanswered = 0, b_unanswered = 0;
  // The rule's three: each delivery after a request that was not quiet,
  // the granted words memory did not hold at it, and at each release the
  // cache's lines and words unlike memory.
  long deliveries = 0, quiet_bad = 0, landall_bad = 0, coh_lines = 0, coh_words = 0, releases = 0;
  // Resets of either kind after the first request; and a hard reset seen
  // since it, after which the rule's three are not asked (it is immediate).
  long resets = 0;
  bool hard_seen = false;
  // `--clear-check`: valid ways at the hard reset's release.
  long valid_after = -1;
  // The read-back program after a hard reset: words read unlike memory, or
  // memory's word neither as written nor as it was.
  long rb_incons = -1;
  long first_request = -1, first_delivery = -1;  // clocks
  bool stopped = false, drained = false;
  long stop_clock = -1;
  uint64_t m26 = 0;
  uint64_t mm[32] = {};
  long mem_bad = -1;
  long ref_coh_checks = 0, ref_coh_bad = 0;
  long rb_granted = -1, rb_lost = -1, rb_w1c = -1, rb_w1u = -1, rb_w2 = -1, rb_corrupt = -1;
  // The face: the write's clock, its answer's, and word 6 read after it.
  long face_wrote = -1, face_answered = -1;
  uint32_t word6 = 0;
  bool word6_read = false;
  // The dead port: the clocks the core was out of reset from its cut to the
  // hard reset, and `rst_cut` at the end.
  long cut_at = -1, held_bad = 0;
  bool cut_end = false;
  struct Txn {
    long valid, accept, done;
  };
  std::vector<Txn> lines, writes;
};

// **THE PORT**: main memory, five bytes a word from byte 5w, and the frame
// buffer's bytes from `kDisplayBase`; one ID a channel, answered in order.
class Port {
 public:
  const Cfg &c_;
  explicit Port(const Cfg &c) : c_(c), mem_(kMainWords * 5, 0), fb_(1280 / 32 * 1024 * 4, 0) {}
  std::vector<uint8_t> mem_, fb_;
  bool dead_ = false, in_reset_ = false;

  uint8_t *byte(uint64_t a) {
    if (a < mem_.size()) return &mem_[a];
    if (a >= kDisplayBase && a - kDisplayBase < fb_.size()) return &fb_[a - kDisplayBase];
    return nullptr;
  }
  void image(uint64_t addr, uint64_t word) {
    for (int b = 0; b < 5; ++b) mem_[addr * 5 + b] = static_cast<uint8_t>(word >> (8 * b));
  }

  struct Ar {
    uint64_t addr;
    int beats, sent = 0, tag;
    long accept, next;
    bool fake = false;
  };
  struct Aw {
    uint64_t addr;
    int beats, got = 0, tag;
    long accept, complete = -1, b_at = -1;
    bool fake = false;
    std::vector<std::pair<uint64_t, uint8_t>> bytes;
  };
  struct W {
    uint8_t data[16];
    uint32_t strb;
    bool last;
    int tag;
  };
  std::deque<Ar> ar_;
  std::deque<Aw> aw_;
  std::deque<W> w_;
  long ar_cnt_ = 0, aw_cnt_ = 0, w_cnt_ = 0;
  bool fake_b_ = false;
  long fake_b_at_ = -1;
  bool dropped_ = false;

  // The port's own reset: what it had of the master's transactions is gone.
  void forget() {
    ar_.clear();
    aw_.clear();
    w_.clear();
    ar_cnt_ = aw_cnt_ = w_cnt_ = 0;
    fake_b_ = false;
    fake_b_at_ = -1;
    dead_ = false;
  }

  void drive(Top *d, long t) {
    const bool off = dead_ || in_reset_;
    d->m_arready = !off && ar_cnt_ >= c_.ar_delay;
    d->m_awready = !off && aw_cnt_ >= c_.aw_delay;
    d->m_wready = !off && w_cnt_ >= c_.w_delay;
    d->m_rvalid = 0;
    d->m_rlast = 0;
    for (int k = 0; k < 4; ++k) d->m_rdata[k] = 0;
    if (!off && !ar_.empty() && ar_.front().next <= t) {
      Ar &a = ar_.front();
      const uint64_t at = a.addr + 8 * uint64_t(a.sent);
      const uint64_t base = at & ~uint64_t(kBus - 1);
      for (int b = 0; b < kBus; ++b) {
        uint8_t v = 0;
        if (const uint8_t *p = byte(base + b)) v = *p;
        if (a.fake) v = uint8_t(0xA5 ^ b);
        d->m_rdata[b / 4] |= uint32_t(v) << (8 * (b % 4));
      }
      d->m_rvalid = 1;
      d->m_rlast = a.sent == a.beats - 1;
    }
    d->m_bvalid = 0;
    if (off) return;
    if (fake_b_ && fake_b_at_ >= 0 && t >= fake_b_at_) {
      d->m_bvalid = 1;
    } else if (!aw_.empty() && aw_.front().b_at >= 0 && aw_.front().b_at <= t) {
      d->m_bvalid = 1;
    }
  }

  // Pair the W beats with the addresses, in order, and schedule the Bs.
  void pair(long t, Counts &n) {
    for (Aw &a : aw_) {
      while (a.got < a.beats && !w_.empty()) {
        W w = w_.front();
        w_.pop_front();
        if (w.tag != a.tag) ++n.misdirected_w;
        if (w.last != (a.got == a.beats - 1)) ++n.wlast_bad;
        const uint64_t at = a.addr + 8 * uint64_t(a.got);
        const uint64_t base = at & ~uint64_t(kBus - 1);
        for (int b = 0; b < kBus; ++b)
          if ((w.strb >> b) & 1) a.bytes.emplace_back(base + b, w.data[b]);
        ++a.got;
      }
      if (a.got == a.beats && a.complete < 0) {
        a.complete = t;
        if (c_.fault == "drop-write" && !dropped_ && !a.fake) {
          dropped_ = true;
        } else {
          for (const auto &p : a.bytes)
            if (uint8_t *q = byte(p.first)) *q = p.second;
        }
        a.b_at = t + c_.lat_b;
      }
      if (a.got < a.beats) break;
    }
  }
};

uint32_t pc_of(uint16_t commit) { return commit & 0x3fff; }

uint64_t pattern(uint64_t w) { return ((w + 1) * 0x9E3779B97F4A7C15ull >> 20) & 0xffffffffffull; }
uint64_t mem_word(const Port &port, uint64_t w) {
  uint64_t v = 0;
  for (int b = 0; b < 5; ++b) v |= uint64_t(port.mem_[w * 5 + b]) << (8 * b);
  return v;
}

// **EVERY VALID LINE AGAINST THE PORT'S MEMORY**: the cache's 4,096 sets of
// two ways (the core's default `CACHE_WORDS`), a way valid when its group's
// bit and its own column bit are set (`quux15_validmap.sv`), its line
// `{tag, set}` (`quux15_port.sv`'s `set_of`, `tag_of`), lane k its row's
// bytes 5k..5k+4.  A main line L's word k is memory's word 8L + k; a frame
// buffer line (`<25>`) holds each four-byte word with the tag 005 above it.
using VMap = QUUX15_VMAP;
// Way `w` of set `s` valid; and every bit of both ways set.
bool way_valid(Top *d, int w, int s) {
  auto *r = d->rootp;
  VMap *m = w ? r->CP(port__DOT__valid1) : r->CP(port__DOT__valid0);
  VlUnpacked<CData, kGroups> *c[64];
  VCOLS(m, c);
  return ((uint64_t(m->__PVT__gv) >> (s >> 6)) & 1) && (*c[s & 63])[s >> 6];
}
void all_valid(Top *d) {
  auto *r = d->rootp;
  for (VMap *m : {r->CP(port__DOT__valid0), r->CP(port__DOT__valid1)}) {
    VlUnpacked<CData, kGroups> *c[64];
    VCOLS(m, c);
    m->__PVT__gv = ~decltype(m->__PVT__gv)(0);
    for (int k = 0; k < 64; ++k)
      for (int g = 0; g < kGroups; ++g) (*c[k])[g] = 1;
  }
}
long count_valid(Top *d) {
  long n = 0;
  for (int w = 0; w < 2; ++w)
    for (int s = 0; s < kSets; ++s) n += way_valid(d, w, s);
  return n;
}

void coherence(Top *d, Port &port, long &lines, long &words, bool verbose, long t) {
  auto *r = d->rootp;
  lines = words = 0;
  for (int w = 0; w < 2; ++w) {
    const auto &tags = w ? r->C(port__DOT__tags1__DOT__mem) : r->C(port__DOT__tags0__DOT__mem);
    const auto &rows = w ? r->C(port__DOT__lines1__DOT__mem) : r->C(port__DOT__lines0__DOT__mem);
    for (int s = 0; s < kSets; ++s) {
      if (!way_valid(d, w, s)) continue;
      const uint64_t line = (uint64_t(tags[s]) << kSetBits) | uint64_t(s);
      auto row_byte = [&](int b) -> uint8_t { return uint8_t(rows[s][b / 4] >> (8 * (b % 4))); };
      long bad = 0;
      for (int k = 0; k < 8; ++k) {
        uint8_t want[5];
        if (line >> 25) {
          const uint64_t a = kDisplayBase + (line & 0x1ffffff) * 32 + 4 * k;
          for (int b = 0; b < 4; ++b) {
            const uint8_t *p = port.byte(a + b);
            want[b] = p ? *p : 0;
          }
          want[4] = 005;
        } else {
          const uint64_t a = line * 40 + 5 * k;
          if (a + 5 > port.mem_.size()) continue;
          for (int b = 0; b < 5; ++b) want[b] = port.mem_[a + b];
        }
        bool same = true;
        for (int b = 0; b < 5; ++b)
          if (row_byte(5 * k + b) != want[b]) same = false;
        if (!same) {
          ++bad;
          if (verbose)
            std::fprintf(stderr, "clock %ld: way %d set %d line %06" PRIx64 " word %d unlike memory\n", t, w, s,
                         line, k);
        }
      }
      if (bad) {
        ++lines;
        words += bad;
      }
    }
  }
}

// The port and this file's port both quiet, after the clock's edge.
bool quiet(Top *d, const Port &port) {
  auto *r = d->rootp;
  return port.ar_.empty() && port.aw_.empty() && port.w_.empty() && !port.fake_b_ &&
         r->C(port__DOT__q_count) == 0 && r->C(port__DOT__f_count) == 0 && r->C(port__DOT__fs) == 0 &&
         r->C(port__DOT__db_v) == 0 && !d->m_arvalid && !d->m_awvalid && !d->m_wvalid;
}

// **THE READ-BACK PROGRAM'S WORDS** (`quux15_memside.rs`'s `resetback`):
// word i of phase 1, even i on four cached lines, odd i a line of its own;
// pass 1's copy of word i at 010000 + i, pass 2's of word 2j at 011000 + j.
uint64_t rb_word(int i) {
  static const uint64_t lines[4] = {04000, 04010, 04020, 04030}, lanes[4] = {1, 3, 4, 6};
  const int j = i / 2;
  return i % 2 == 0 ? lines[j / 4] + lanes[j % 4] : 05000 + 8 * j + (j % 8);
}
constexpr int kRbWords = 32;
constexpr uint64_t kRbCopy1 = 010000, kRbCopy2 = 011000;

// The bouncing button's request: twelve pulses of 1 to 10 clocks, 1 to
// 1,000 clocks apart, from `at`, drawn from `seed`.
std::vector<std::pair<long, long>> bounce_train(long at, long seed) {
  std::vector<std::pair<long, long>> v;
  uint64_t s = uint64_t(seed) * 0x9E3779B97F4A7C15ull + 1;
  auto next = [&]() {
    s = s * 6364136223846793005ull + 1442695040888963407ull;
    return long(s >> 33);
  };
  long t = at;
  for (int k = 0; k < 12; ++k) {
    const long len = 1 + next() % 10;
    v.emplace_back(t, len);
    t += len + 1 + next() % 1000;
  }
  return v;
}

// One run: `cfg`'s request (or none).  `ref_mem` is the run with no reset's
// memory, held against at the end when given.
Counts one(const Run &run, const Cfg &cfg, const std::vector<uint8_t> *ref_mem, std::vector<uint8_t> *mem_out,
           int seed) {
  Counts n;
  Verilated::gotFinish(false);
  Verilated::randSeed(seed);
  Top *d = new Top;
  auto *r = d->rootp;
  Port port(cfg);
  // **MAIN MEMORY COMES UP PATTERNED**, every word its own, so that a beat
  // of another line is never the right bytes by luck.
  for (uint64_t w = 0; w < kMainWords; ++w) port.image(w, pattern(w));
  for (const Image &i : run.images)
    if (i.memory == "main" && i.address < kMainWords) port.image(i.address, i.word);

  d->hard = 1;
  d->req = 0;
  d->f_awaddr = 0; d->f_awvalid = 0; d->f_wdata = 0; d->f_wvalid = 0; d->f_bready = 1;
  d->f_araddr = 0; d->f_arvalid = 0; d->f_rready = 1;
  d->m_awready = 0; d->m_wready = 0; d->m_arready = 0;
  d->m_bvalid = 0; d->m_rvalid = 0; d->m_rlast = 0;
  for (int k = 0; k < 4; ++k) d->m_rdata[k] = 0;
  d->clk = 0;
  d->eval();
  for (const Image &i : run.images) {
    if (i.memory == "prom" && i.address < 1024)
      r->C(store__DOT__prom)[i.address] = i.word;
    else if (i.memory == "imem" && i.address < 16384)
      r->C(store__DOT__ram__DOT__mem)[i.address] = i.word ^ 0x0000ffffffffffffull;
    else if (i.memory == "amem" && i.address < 1024) {
      uint64_t w = i.word;
      for (const auto &m : cfg.amem)
        if (w == m.first) w = m.second;
      r->C(amem__DOT__mem)[i.address] = w & 0xffffffffffull;
    } else if (i.memory == "mmem" && i.address < 32)
      r->C(mmem)[i.address] = i.word & 0xffffffffffull;
    else if (i.memory == "dmem" && i.address < 4096 && i.address % 2 == 0)
      r->C(u_dmem__DOT__even)[i.address / 2] = static_cast<uint32_t>(i.word & 0x1ffff);
    else if (i.memory == "dmem" && i.address < 4096)
      r->C(u_dmem__DOT__odd)[i.address / 2] = static_cast<uint32_t>(i.word & 0x1ffff);
    else if (i.memory == "mdmem" && i.address < 1024)
      r->C(u_mdmem__DOT__mem)[i.address] = static_cast<uint32_t>(i.word & 0x3ffff);
    else if (i.memory == "pdl" && i.address < 16384)
      r->C(pdl__DOT__mem)[i.address] = i.word & 0xffffffffffull;
  }
  for (int k = 0; k < 4; ++k) {
    d->clk = 0;
    d->eval();
    d->clk = 1;
    d->eval();
  }
  d->hard = 0;
  d->clk = 0;
  d->eval();
  if (run.skip_sweep) {
    r->C(mmu__DOT__sweep_left) = 0;
    d->eval();
  }

  const auto train = cfg.bounce >= 0 ? bounce_train(cfg.reset_at, cfg.bounce) : std::vector<std::pair<long, long>>{};
  long req_last = -1;  // the request's last clock
  if (cfg.reset_at >= 0) req_last = cfg.bounce >= 0 ? train.back().first + train.back().second - 1
                                                    : cfg.reset_at + cfg.reset_len - 1;
  if (cfg.face_at >= 0) req_last = std::max(req_last, cfg.face_at + 64);
  int gen = 0;
  bool was_on = false;
  long released = -1;  // the last release's first clock
  bool cur_v = false;
  std::vector<uint8_t> cur_line;
  bool ar_pend = false, aw_pend = false, w_pend = false;
  bool fault_done = false;
  long ar_valid_since = -1, aw_valid_since = -1;
  std::deque<long> ar_line_idx;
  std::deque<long> aw_write_idx;
  // The read-back program's jump to its phase 2.
  uint64_t resume_word = 0;
  const long resume_at = cfg.resume_at >= 0 ? cfg.resume_at : -1;
  if (resume_at >= 0) {
    uint64_t prom0 = 0, stopw = 0;
    for (const Image &i : run.images) {
      if (i.memory == "prom" && i.address == 0) prom0 = i.word;
      if (i.memory == "imem" && i.address == kStop) stopw = i.word;
    }
    int sh = -1;
    for (int k = 0; k < 50 && sh < 0; ++k)
      if ((prom0 | (uint64_t(kStop) << k)) == stopw) sh = k;
    if (sh < 0) {
      std::fprintf(stderr, "--resume-at: no target field found from %" PRIx64 " and %" PRIx64 "\n", prom0, stopw);
      std::exit(2);
    }
    resume_word = prom0 | (uint64_t(resume_at) << sh);
  }
  std::map<uint64_t, uint64_t> granted;      // before the first reset, for the read-back
  std::map<uint64_t, uint64_t> gen_granted;  // since the last release, for land-all
  // The face's write: 0 none, 1 address and beat offered, 2 waiting for B,
  // 3 answered, reading word 6, 4 done.
  int face = 0;
  long stop_at = -1;
  long t = 0;
  for (;; ++t) {
    // --- The inputs for this clock.
    bool req = false;
    if (cfg.bounce >= 0) {
      for (const auto &p : train)
        if (t >= p.first && t < p.first + p.second) req = true;
    } else if (cfg.reset_at >= 0) {
      req = t >= cfg.reset_at && t < cfg.reset_at + cfg.reset_len;
    }
    const bool hard = cfg.hard_at >= 0 && t >= cfg.hard_at && t < cfg.hard_at + cfg.hard_len;
    // The port's own reset: the port takes nothing and answers nothing while
    // it lasts, and forgets what it had.
    if (hard) port.forget();
    port.in_reset_ = hard;
    if (cfg.dead_at >= 0 && t == cfg.dead_at) port.dead_ = true;
    if (cfg.errhalt_at >= 0 && t == cfg.errhalt_at) r->C(errhalt) = 1;
    if (cfg.halt_at >= 0 && t == cfg.halt_at) r->C(cc_run) = 0;
    if (cfg.clear_check && t == cfg.hard_at) all_valid(d);
    if (req && n.first_request < 0) n.first_request = t;
    d->req = req;
    d->hard = hard;
    // The face's page, as the processing system's store and load.
    if (cfg.face_at >= 0 && t == cfg.face_at && face == 0) {
      face = 1;
      n.face_wrote = t;
      if (n.first_request < 0) n.first_request = t;
    }
    d->f_awaddr = 6 * 4;
    d->f_wdata = kResetKey;
    d->f_awvalid = face == 1;
    d->f_wvalid = face == 1;
    d->f_araddr = 6 * 4;
    d->f_arvalid = face == 3;
    port.drive(d, t);
    d->clk = 0;
    d->eval();

    const bool on = d->core_on;
    const bool ar_hs = d->m_arvalid && d->m_arready;
    const bool r_hs = d->m_rvalid && d->m_rready;
    const bool aw_hs = d->m_awvalid && d->m_awready;
    const bool w_hs = d->m_wvalid && d->m_wready;
    const bool b_hs = d->m_bvalid && d->m_bready;
    const int tag = gen;
    const uint8_t rstate = r->C(port__DOT__master__DOT__rstate);

    // **THE RESET RISES**: after a request, quiet and every granted write
    // in memory.
    if (hard && n.first_request >= 0) n.hard_seen = true;
    if (on && !was_on && n.first_request >= 0) ++n.resets;
    if (on && !was_on) {
      if (cfg.verbose) std::fprintf(stderr, "clock %ld: the reset rises\n", t);
      if (!hard && !n.hard_seen && n.first_request >= 0 && t >= n.first_request) {
        ++n.deliveries;
        if (n.first_delivery < 0) n.first_delivery = t;
        const bool q = !d->m_arvalid && !d->m_awvalid && !d->m_wvalid && port.ar_.empty() && port.aw_.empty() &&
                       port.w_.empty();
        if (!q && !port.dead_) {
          ++n.quiet_bad;
          if (cfg.verbose)
            std::fprintf(stderr, "clock %ld: the reset rises with arvalid %d awvalid %d wvalid %d, %zu reads, %zu "
                         "writes, %zu beats owed\n", t, d->m_arvalid, d->m_awvalid, d->m_wvalid, port.ar_.size(),
                         port.aw_.size(), port.w_.size());
        }
        if (port.dead_ && n.cut_at < 0) n.cut_at = t;
        if (!port.dead_)
          for (const auto &g : gen_granted)
            if (g.first < kMainWords && mem_word(port, g.first) != g.second) {
              ++n.landall_bad;
              if (cfg.verbose)
                std::fprintf(stderr, "clock %ld: granted word %06" PRIo64 " %010" PRIx64 " not in memory (%010" PRIx64
                             ")\n", t, g.first, g.second, mem_word(port, g.first));
            }
      }
      if (resume_at >= 0 && gen == 0) r->C(store__DOT__prom)[0] = resume_word;
      if (cfg.fault == "ghost-aw" && gen == 0) {
        Port::Aw a;
        a.addr = 0x1000;
        a.beats = 1;
        a.tag = kTagLost;
        a.accept = t;
        a.fake = true;
        port.aw_.push_front(a);
      }
    }

    // VALID withdrawn without READY.
    if (ar_pend && !d->m_arvalid) ++n.drop_ar;
    if (aw_pend && !d->m_awvalid) ++n.drop_aw;
    if (w_pend && !d->m_wvalid) ++n.drop_w;
    ar_pend = d->m_arvalid && !d->m_arready;
    aw_pend = d->m_awvalid && !d->m_awready;
    w_pend = d->m_wvalid && !d->m_wready;
    if (hard) ar_pend = aw_pend = w_pend = false;  // the port's own reset ends both sides
    port.ar_cnt_ = d->m_arvalid && !ar_hs ? port.ar_cnt_ + 1 : 0;
    port.aw_cnt_ = d->m_awvalid && !aw_hs ? port.aw_cnt_ + 1 : 0;
    port.w_cnt_ = d->m_wvalid && !w_hs ? port.w_cnt_ + 1 : 0;
    if (d->m_arvalid && ar_valid_since < 0) ar_valid_since = t;
    if (d->m_awvalid && aw_valid_since < 0) aw_valid_since = t;

    // A line the master completes at this edge.
    if (!on && r_hs && rstate != 0) {
      const uint8_t beat = r->C(port__DOT__master__DOT__beat);
      const bool win = r->C(port__DOT__master__DOT__r_win);
      if (beat == (win ? 3 : 4) && !win) {
        const auto &rd = r->C(port__DOT__rd_data);
        bool same = cur_v;
        for (int b = 0; b < 40 && same; ++b)
          if (uint8_t(rd[b / 4] >> (8 * (b % 4))) != cur_line[b]) same = false;
        if (!same) {
          ++n.fill_wrong;
          if (cfg.verbose) std::fprintf(stderr, "clock %ld: a line completed with the wrong bytes\n", t);
        }
      }
    }

    // The read address.
    if (ar_hs) {
      Port::Ar a;
      a.addr = d->m_araddr;
      a.beats = int(d->m_arlen) + 1;
      a.tag = tag;
      a.accept = t;
      const long after = port.ar_.empty() ? 0 : port.ar_.back().next + (port.ar_.back().beats - port.ar_.back().sent);
      a.next = std::max(t + 1 + cfg.lat_r, after);
      port.ar_.push_back(a);
      const bool win = a.addr >= kDisplayBase;
      const bool first = win ? a.addr % 32 == 0 : (a.addr % 40 == 0);
      if (first) {
        n.lines.push_back({ar_valid_since >= 0 ? ar_valid_since : t, t, -1});
        if (!on) {
          cur_v = true;
          cur_line.assign(40, 0);
          for (int b = 0; b < 40; ++b)
            if (const uint8_t *p = port.byte(a.addr + b)) cur_line[b] = *p;
        }
      }
      ar_line_idx.push_back(long(n.lines.size()) - 1);
      ar_valid_since = -1;
      if (!fault_done && cfg.fault == "extra-r" && gen > 0 && !on) {
        Port::Ar f;
        f.addr = 0;
        f.beats = 1;
        f.tag = kTagLost;
        f.accept = t;
        f.next = t + 1;
        f.fake = true;
        port.ar_.push_front(f);
        fault_done = true;
      }
    }
    if (!fault_done && cfg.fault == "extra-r-idle" && gen > 0 && !on && t == released + 2) {
      Port::Ar f;
      f.addr = 0;
      f.beats = 1;
      f.tag = kTagLost;
      f.accept = t;
      f.next = t + 1;
      f.fake = true;
      port.ar_.push_front(f);
      fault_done = true;
    }
    // A beat.
    if (r_hs && !port.ar_.empty() && port.ar_.front().next <= t) {
      Port::Ar &a = port.ar_.front();
      if (on) ++n.r_in_reset;
      else if (a.tag != gen) (rstate == 0 ? ++n.stray_r_idle : ++n.stray_r_fill);
      ++a.sent;
      a.next = t + 1 + cfg.r_gap;
      if (a.sent == a.beats) {
        if (!a.fake && !ar_line_idx.empty()) {
          const long li = ar_line_idx.front();
          if (li >= 0) n.lines[li].done = t;
          ar_line_idx.pop_front();
        }
        port.ar_.pop_front();
        if (!port.ar_.empty()) port.ar_.front().next = std::max(port.ar_.front().next, t + 1 + cfg.r_gap);
      }
    }
    // The write address and its beats.
    if (aw_hs) {
      Port::Aw a;
      a.addr = d->m_awaddr;
      a.beats = int(d->m_awlen) + 1;
      a.tag = tag;
      a.accept = t;
      port.aw_.push_back(a);
      // A write is one or two addresses; a split's second address is at a
      // 4 KiB boundary, with one beat, within a few clocks of its first.
      const bool second = (a.addr & 0xfff) == 0 && !n.writes.empty() && n.writes.back().done < 0 &&
                          !aw_write_idx.empty() && aw_write_idx.back() == long(n.writes.size()) - 1 &&
                          t - n.writes.back().accept <= 3;
      if (!second) n.writes.push_back({aw_valid_since >= 0 ? aw_valid_since : t, t, -1});
      aw_write_idx.push_back(long(n.writes.size()) - 1);
      aw_valid_since = -1;
      if (!fault_done && cfg.fault == "extra-b" && gen > 0 && !on) {
        port.fake_b_ = true;
        port.fake_b_at_ = t + 1;
        fault_done = true;
      }
    }
    if (w_hs) {
      Port::W w;
      for (int b = 0; b < 16; ++b) w.data[b] = uint8_t(d->m_wdata[b / 4] >> (8 * (b % 4)));
      w.strb = d->m_wstrb;
      w.last = d->m_wlast;
      w.tag = tag;
      port.w_.push_back(w);
    }
    port.pair(t, n);
    if (!fault_done && cfg.fault == "drop-b" && gen > 0 && !on)
      for (Port::Aw &a : port.aw_)
        if (a.tag == gen && a.complete >= 0) {
          a.b_at = 1L << 60;
          fault_done = true;
          break;
        }
    // A B.
    if (b_hs) {
      if (port.fake_b_ && port.fake_b_at_ >= 0 && t >= port.fake_b_at_) {
        port.fake_b_ = false;
        port.fake_b_at_ = -1;
        if (!on) ++n.late_b;
      } else if (!port.aw_.empty() && port.aw_.front().b_at >= 0 && port.aw_.front().b_at <= t) {
        Port::Aw &a = port.aw_.front();
        if (on) ++n.b_in_reset;
        else if (a.tag != gen) ++n.late_b;
        if (!aw_write_idx.empty()) {
          const long wi = aw_write_idx.front();
          if (wi >= 0) n.writes[wi].done = t;
          aw_write_idx.pop_front();
        }
        port.aw_.pop_front();
      }
    }

    // The face's channels at this edge.
    if (face == 1 && d->f_wvalid && d->f_wready) face = 2;
    else if (face == 2 && d->f_bvalid) {
      face = 3;
      n.face_answered = t;
    } else if (face == 3 && d->f_rvalid) {
      n.word6 = d->f_rdata;
      n.word6_read = true;
      face = 4;
    }

    // A write the port grants at this edge.
    const bool w_push = r->C(port__DOT__w_push) && !on;
    const int w_slot = r->C(port__DOT__w_slot);

    d->clk = 1;
    d->eval();

    if (w_push) {
      const uint64_t bus = r->C(port__DOT__q_bus)[w_slot];
      const uint64_t word = r->C(port__DOT__q_word)[w_slot] & 0xffffffffffull;
      if (gen == 0) granted[bus] = word;
      gen_granted[bus] = word;
    }
    // The dead port's hold: once cut, the core stays in reset until the
    // hard reset.
    if (n.cut_at >= 0 && !on && (cfg.hard_at < 0 || t < cfg.hard_at)) ++n.held_bad;

    // **THE RESET FALLS**: the cache against memory, and the program after
    // it asking for other addresses.
    if (was_on && !on) {
      ++gen;
      released = t;
      if (cfg.verbose) std::fprintf(stderr, "clock %ld: the reset falls\n", t);
      cur_v = false;
      gen_granted.clear();
      if (cfg.clear_check && n.valid_after < 0 && cfg.hard_at >= 0 && t > cfg.hard_at)
        n.valid_after = count_valid(d);
      // After a request or a hard reset: the cache against memory.
      if (!hard && (n.first_request >= 0 || (cfg.hard_at >= 0 && t > cfg.hard_at))) {
        long l, w;
        coherence(d, port, l, w, cfg.verbose, t);
        ++n.releases;
        n.coh_lines += l;
        n.coh_words += w;
      }
      if (cfg.sweep_after) r->C(mmu__DOT__sweep_left) = 0;
      for (int k = 0; k < 1024; ++k)
        for (const auto &m : cfg.amem_after)
          if (r->C(amem__DOT__mem)[k] == (m.first & 0xffffffffffull)) r->C(amem__DOT__mem)[k] = m.second & 0xffffffffffull;
      d->eval();
    }
    was_on = on;
    // The run with no reset: the cache against memory at every quiet clock.
    if (!cfg.any_request() && cfg.hard_at < 0 && quiet(d, port)) {
      long l, w;
      coherence(d, port, l, w, cfg.verbose && n.ref_coh_bad == 0, t);
      ++n.ref_coh_checks;
      if (l) ++n.ref_coh_bad;
    }

    // The program's stop, after the last release.
    const bool settled_inputs = t > req_last && (cfg.hard_at < 0 || t >= cfg.hard_at + cfg.hard_len);
    const long disturbed = std::max(n.first_request, cfg.hard_at);
    if (disturbed >= 0 && !on && settled_inputs && released > disturbed && stop_at < 0) {
      const uint16_t c = d->obs_commit;
      if ((c >> 15) & 1 && !((c >> 14) & 1) && pc_of(c) == kStop) {
        stop_at = t;
        n.stopped = true;
        n.stop_clock = t;
      }
    } else if (!cfg.any_request() && cfg.hard_at < 0 && stop_at < 0) {
      const uint16_t c = d->obs_commit;
      if ((c >> 15) & 1 && !((c >> 14) & 1) && pc_of(c) == kStop) {
        stop_at = t;
        n.stopped = true;
        n.stop_clock = t;
      }
    }
    // Done: stopped and every answer in, the face's word read.
    const long settle = 4L * (cfg.lat_r + cfg.lat_b + cfg.r_gap * 5 + cfg.aw_delay + cfg.w_delay + 20) + 200;
    if (stop_at >= 0 && t >= stop_at + settle && (cfg.face_at < 0 || face == 4)) break;
    const long from = std::max({released, req_last, cfg.hard_at >= 0 ? cfg.hard_at + cfg.hard_len : 0L, 0L});
    if (settled_inputs && t >= from + cfg.budget) break;
  }
  n.drained = d->obs_queue == 0 && d->obs_inflight == 0;
  n.cut_end = d->core_cut;
  if (resume_at >= 0) {
    auto expect = [&](uint64_t w) {
      const auto g = granted.find(w);
      return g != granted.end() ? g->second : pattern(w);
    };
    std::vector<bool> mine(kMainWords, false);
    n.rb_granted = n.rb_lost = n.rb_w1c = n.rb_w1u = n.rb_w2 = n.rb_corrupt = 0;
    if (n.hard_seen || (cfg.hard_at >= 0 && n.first_request < 0)) {
      // A hard reset drops what the port had queued: each word is as
      // written or as it was, and read alike from the cache and from
      // memory.
      n.rb_incons = 0;
      for (int i = 0; i < kRbWords; ++i) {
        const uint64_t a = rb_word(i), m = mem_word(port, a);
        mine[a] = mine[kRbCopy1 + i] = true;
        if (granted.count(a)) ++n.rb_granted;
        if (m != pattern(a) && !(granted.count(a) && granted[a] == m)) ++n.rb_incons;
        if (mem_word(port, kRbCopy1 + i) != m) ++n.rb_incons;
        if (i % 2 == 0) {
          mine[kRbCopy2 + i / 2] = true;
          if (mem_word(port, kRbCopy2 + i / 2) != m) ++n.rb_incons;
        }
      }
      for (uint64_t w = 0; w < kMainWords; ++w)
        if (!mine[w] && mem_word(port, w) != pattern(w)) ++n.rb_corrupt;
    } else
    for (int i = 0; i < kRbWords; ++i) {
      const uint64_t a = rb_word(i), e = expect(a);
      mine[a] = mine[kRbCopy1 + i] = true;
      if (granted.count(a)) ++n.rb_granted;
      if (mem_word(port, a) != e) {
        if (granted.count(a)) ++n.rb_lost;
        else ++n.rb_corrupt;
      }
      if (mem_word(port, kRbCopy1 + i) != e) (i % 2 == 0 ? ++n.rb_w1c : ++n.rb_w1u);
      if (i % 2 == 0) {
        mine[kRbCopy2 + i / 2] = true;
        if (mem_word(port, kRbCopy2 + i / 2) != e) ++n.rb_w2;
      }
    }
    for (uint64_t w = 0; w < kMainWords; ++w)
      if (!mine[w] && mem_word(port, w) != pattern(w)) ++n.rb_corrupt;
  }
  n.m26 = r->C(mmem)[026];
  for (int k = 0; k < 32; ++k) n.mm[k] = r->C(mmem)[k];
  for (const Port::Aw &a : port.aw_) {
    if (a.got < a.beats) ++n.orphan_aw;
    else ++n.b_unanswered;
  }
  n.orphan_w = long(port.w_.size());
  n.ar_unanswered = long(port.ar_.size());
  if (ref_mem) {
    long bad = 0;
    for (size_t k = 0; k < port.mem_.size(); ++k)
      if (port.mem_[k] != (*ref_mem)[k]) ++bad;
    n.mem_bad = bad;
  }
  if (mem_out) *mem_out = port.mem_;
  d->final();
  delete d;
  return n;
}

const uint64_t *g_ref_mm = nullptr;
bool m_differs(const Counts &n) {
  if (!g_ref_mm) return false;
  for (int k = 0; k < 32; ++k)
    if (n.mm[k] != g_ref_mm[k]) return true;
  return false;
}
bool misbehaves(const Counts &n, const Cfg &cfg, std::string &why) {
  why.clear();
  auto add = [&](const char *s, long v) {
    if (v) {
      if (!why.empty()) why += ",";
      why += s;
      why += "=" + std::to_string(v);
    }
  };
  add("stray_r_idle", n.stray_r_idle);
  add("stray_r_fill", n.stray_r_fill);
  add("late_b", n.late_b);
  add("misdirected_w", n.misdirected_w);
  add("wlast_bad", n.wlast_bad);
  add("drop_ar", n.drop_ar);
  add("drop_aw", n.drop_aw);
  add("drop_w", n.drop_w);
  add("fill_wrong", n.fill_wrong);
  add("orphan_aw", n.orphan_aw);
  add("orphan_w", n.orphan_w);
  add("ar_unanswered", n.ar_unanswered);
  add("b_unanswered", n.b_unanswered);
  add("quiet_bad", n.quiet_bad);
  add("landall_bad", n.landall_bad);
  add("coh_words", n.coh_words);
  if (cfg.any_request() && n.resets == 0) add("no_reset", 1);
  if (!n.stopped) add("hang", 1);
  else if (!n.drained) add("not_drained", 1);
  if (n.stopped && m_differs(n)) add("m_wrong", 1);
  if (n.mem_bad > 0) add("mem_bad_bytes", n.mem_bad);
  if (n.rb_incons >= 0) add("incons", n.rb_incons);
  if (cfg.clear_check && n.valid_after != 0) add("valid_after", n.valid_after < 0 ? 1 : n.valid_after);
  if (n.rb_lost >= 0) {
    add("lost", n.rb_lost);
    add("w1c", n.rb_w1c);
    add("w1u", n.rb_w1u);
    add("w2", n.rb_w2);
    add("corrupt", n.rb_corrupt);
  }
  // A cut is a fault of the port's and only the dead port's leg expects one.
  if (cfg.dead_at < 0 && n.cut_end) add("cut", 1);
  if (cfg.dead_at >= 0) {
    // The cut within the core's bound of the request, held until the hard
    // reset, recorded and kept.
    if (n.cut_at < 0 || n.cut_at - n.first_request > kCoreBound + 8) add("cut_late", 1);
    add("held_bad", n.held_bad);
    if (!n.cut_end) add("cut_lost", 1);
  }
  if (cfg.face_at >= 0) {
    // The answer: within the face's bound always; after the machine's reset
    // when the port drains; at the bound, the cut recorded, when it does not.
    const long lat = n.face_answered < 0 ? -1 : n.face_answered - n.face_wrote;
    if (lat < 0 || lat > kAnswerBound + 8) add("face_unanswered", 1);
    if (!n.word6_read) add("word6_unread", 1);
    const bool bound = (n.word6 >> 2) & 1, cut = (n.word6 >> 3) & 1;
    if (cfg.dead_at < 0 && (bound || cut || n.face_answered < n.first_delivery)) add("face_early_or_bound", 1);
    if (cfg.dead_at >= 0 && (!bound || !cut)) add("face_word6", 1);
  }
  return !why.empty();
}

void print(const char *what, long pos, const Counts &n, const Cfg &cfg) {
  std::string why;
  const bool bad = misbehaves(n, cfg, why);
  std::printf("%s pos %ld: %s r_in_reset=%ld b_in_reset=%ld stop=%ld delivered=%ld after %ld releases=%ld coh=%ld/%ld",
              what, pos, bad ? "MISBEHAVES" : "ok", n.r_in_reset, n.b_in_reset, n.stop_clock, n.deliveries,
              n.first_delivery >= 0 ? n.first_delivery - n.first_request : -1, n.releases, n.coh_lines,
              n.coh_words);
  if (n.rb_lost >= 0)
    std::printf(" rb granted=%ld lost=%ld w1c=%ld w1u=%ld w2=%ld corrupt=%ld", n.rb_granted, n.rb_lost, n.rb_w1c,
                n.rb_w1u, n.rb_w2, n.rb_corrupt);
  if (cfg.face_at >= 0)
    std::printf(" face answered %ld after the write, word6 %08x", n.face_answered - n.face_wrote, n.word6);
  if (cfg.dead_at >= 0) std::printf(" cut %ld after the request, held_bad %ld, rst_cut %d", n.cut_at - n.first_request,
                                    n.held_bad, int(n.cut_end));
  std::printf(" %s\n", bad ? why.c_str() : "");
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Verilated::randReset(2);
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <trace> <run> [options]\n", argv[0]);
    return 2;
  }
  Run run;
  if (!read_run(argv[1], argv[2], run)) {
    std::fprintf(stderr, "no run %s in %s\n", argv[2], argv[1]);
    return 2;
  }
  Cfg cfg;
  std::string sweep;
  long target = 0, step = 1;
  int seed = 1;
  bool resume = false, first = false, hard_sweep = false;
  for (int k = 3; k < argc; ++k) {
    std::string a = argv[k];
    auto num = [&]() -> long { return k + 1 < argc ? std::strtol(argv[++k], nullptr, 0) : 0; };
    auto pair = [&](std::vector<std::pair<uint64_t, uint64_t>> &v) {
      const char *s = argv[++k];
      char *e;
      const uint64_t o = std::strtoull(s, &e, 16);
      v.emplace_back(o, *e == '=' ? std::strtoull(e + 1, nullptr, 16) : o);
    };
    if (a == "--lat-r") cfg.lat_r = int(num());
    else if (a == "--lat-b") cfg.lat_b = int(num());
    else if (a == "--r-gap") cfg.r_gap = int(num());
    else if (a == "--aw-delay") cfg.aw_delay = int(num());
    else if (a == "--w-delay") cfg.w_delay = int(num());
    else if (a == "--ar-delay") cfg.ar_delay = int(num());
    else if (a == "--reset-at") cfg.reset_at = num();
    else if (a == "--reset-len") cfg.reset_len = int(num());
    else if (a == "--bounce") cfg.bounce = num();
    else if (a == "--face-at") cfg.face_at = num();
    else if (a == "--hard-at") cfg.hard_at = num();
    else if (a == "--hard-len") cfg.hard_len = int(num());
    else if (a == "--dead-at") cfg.dead_at = num();
    else if (a == "--errhalt-at") cfg.errhalt_at = num();
    else if (a == "--halt-at") cfg.halt_at = num();
    else if (a == "--sweep-after-reset") cfg.sweep_after = true;
    else if (a == "--budget") cfg.budget = num();
    else if (a == "--seed") seed = int(num());
    else if (a == "--verbose") cfg.verbose = true;
    else if (a == "--fault" && k + 1 < argc) cfg.fault = argv[++k];
    else if (a == "--sweep" && k + 1 < argc) sweep = argv[++k];
    else if (a == "--target") target = num();
    else if (a == "--step") step = std::max(1L, num());
    else if (a == "--resume-at") cfg.resume_at = num();
    else if (a == "--resume") resume = true;
    else if (a == "--first") first = true;
    else if (a == "--sweep-hard") hard_sweep = true;
    else if (a == "--clear-check") cfg.clear_check = true;
    else if (a == "--amem" && k + 1 < argc) pair(cfg.amem);
    else if (a == "--amem-after" && k + 1 < argc) pair(cfg.amem_after);
    else if (a.rfind("+", 0) == 0) {
    } else {
      std::fprintf(stderr, "unknown option %s\n", a.c_str());
      return 2;
    }
  }
  if (resume && cfg.resume_at < 0) {
    if (run.resume < 0) {
      std::fprintf(stderr, "--resume: the run %s has no `# resume` line\n", run.name.c_str());
      return 2;
    }
    cfg.resume_at = run.resume;
  }

  // The run with no request: the reference.
  Cfg ref_cfg = cfg;
  ref_cfg.reset_at = ref_cfg.face_at = ref_cfg.hard_at = ref_cfg.dead_at = ref_cfg.errhalt_at = ref_cfg.halt_at = -1;
  ref_cfg.bounce = -1;
  ref_cfg.clear_check = false;
  ref_cfg.fault.clear();
  std::vector<uint8_t> ref_mem;
  Counts ref = one(run, ref_cfg, nullptr, &ref_mem, seed);
  const bool rb = cfg.resume_at >= 0;
  g_ref_mm = cfg.amem_after.empty() && !rb ? ref.mm : nullptr;
  const std::vector<uint8_t> *cmp_mem =
      rb || cfg.errhalt_at >= 0 || cfg.dead_at >= 0 || cfg.hard_at >= 0 || hard_sweep ? nullptr : &ref_mem;
  if (ref.ref_coh_bad || ref.ref_coh_checks == 0) {
    std::printf("FAIL: the run with no reset has the cache unlike memory at %ld of %ld quiet clocks\n",
                ref.ref_coh_bad, ref.ref_coh_checks);
    return 1;
  }
  if (rb && (ref.rb_lost || ref.rb_w1c || ref.rb_w1u || ref.rb_w2 || ref.rb_corrupt || ref.rb_granted != kRbWords)) {
    std::printf("FAIL: the read-back program with no reset reads wrong\n");
    return 1;
  }
  {
    std::string why;
    Counts r2 = ref;
    r2.mem_bad = 0;
    if (misbehaves(r2, ref_cfg, why) || !ref.stopped) {
      std::printf("FAIL: the run with no reset is not clean: %s\n", why.c_str());
      return 1;
    }
  }
  std::printf("# board %d %s %s: lat_r=%d lat_b=%d r_gap=%d ar_delay=%d aw_delay=%d w_delay=%d reset_len=%d "
              "sweep_after=%d fault=%s; no reset: stop at %ld, %zu lines, %zu writes, the cache equal to memory at "
              "all %ld quiet clocks\n",
              kBoard, argv[1], run.name.c_str(), cfg.lat_r, cfg.lat_b, cfg.r_gap, cfg.ar_delay, cfg.aw_delay,
              cfg.w_delay, cfg.reset_len, int(cfg.sweep_after), cfg.fault.empty() ? "none" : cfg.fault.c_str(),
              ref.stop_clock, ref.lines.size(), ref.writes.size(), ref.ref_coh_checks);

  if (sweep.empty()) {
    if (!cfg.any_request() && cfg.hard_at < 0) {
      for (size_t k = 0; k < ref.lines.size(); ++k)
        std::printf("# line %zu: valid %ld accept %ld last beat %ld\n", k, ref.lines[k].valid, ref.lines[k].accept,
                    ref.lines[k].done);
      for (size_t k = 0; k < ref.writes.size(); ++k)
        std::printf("# write %zu: valid %ld accept %ld B %ld\n", k, ref.writes[k].valid, ref.writes[k].accept,
                    ref.writes[k].done);
      return 0;
    }
    Counts n = one(run, cfg, cmp_mem, nullptr, seed);
    print("single", cfg.reset_at >= 0 ? cfg.reset_at : cfg.face_at, n, cfg);
    std::string why;
    return misbehaves(n, cfg, why) ? 3 : 0;
  }

  const auto &txns = sweep == "read" ? ref.lines : ref.writes;
  const bool span = sweep == "write-span";
  if (span ? (target < 1 || size_t(target) > txns.size()) : (target < 0 || size_t(target) >= txns.size())) {
    std::printf("FAIL: no %s %ld in the run (%zu)\n", sweep.c_str(), target, txns.size());
    return 1;
  }
  const Counts::Txn x = span ? Counts::Txn{txns[0].valid, txns[0].accept, txns[target - 1].done} : txns[target];
  long tried = 0, bad = 0;
  std::map<std::string, long> tally;
  for (long p = x.valid; p <= x.done + 1; p += step) {
    Cfg c = cfg;
    if (hard_sweep) c.hard_at = p;
    else if (c.face_at >= 0) c.face_at = p;
    else c.reset_at = p;
    Counts n = one(run, c, cmp_mem, nullptr, seed);
    ++tried;
    std::string why;
    if (misbehaves(n, c, why)) {
      ++bad;
      size_t s = 0;
      while (s < why.size()) {
        size_t e = why.find(',', s);
        if (e == std::string::npos) e = why.size();
        const std::string item = why.substr(s, e - s);
        ++tally[item.substr(0, item.find('='))];
        s = e + 1;
      }
    }
    print(sweep.c_str(), p, n, c);
    std::fflush(stdout);
    if (first && bad) break;
  }
  std::printf("SUMMARY board %d %s %s target %ld (valid %ld accept %ld done %ld) lat_r=%d lat_b=%d "
              "ar/aw/w_delay=%d/%d/%d r_gap=%d reset_len=%d sweep_after=%d fault=%s: %ld positions, %ld misbehave;",
              kBoard, sweep.c_str(), run.name.c_str(), target, x.valid, x.accept, x.done, cfg.lat_r, cfg.lat_b,
              cfg.ar_delay, cfg.aw_delay, cfg.w_delay, cfg.r_gap, cfg.reset_len, int(cfg.sweep_after),
              cfg.fault.empty() ? "none" : cfg.fault.c_str(), tried, bad);
  for (const auto &k : tally) std::printf(" %s@%ld", k.first.c_str(), k.second);
  std::printf("\n");
  return bad ? 3 : 0;
}
