// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Holds revision 15's console face (`rtl/plumbing/quux15_face.sv`) to the
// words its header gives, driven over AXI as Linux's programs drive it, one
// beat a transaction, with the core behind it modeled here: its readout a word
// three clocks after its address, each word a function of the address alone;
// the diagnostic registers a function of the register; the counters and VMA,
// Q and MD moving every clock, so that a latch taken at the wrong read shows.
//
//   - IDENT, and UNMAPPED at a word the face does not name;
//   - no reset asked for from power-on, as revisions 13 and 14 come up on the
//     boards; a write of RESET's key with all four strobes asks for one, a
//     request RESET_T clocks long; another value, or the key with a strobe
//     off, does nothing; the count of resets.  **ITS ANSWER**: with a core
//     here that drains for a while and is then in its reset, the write's B
//     comes once the core is out of it again, not before; with a core that
//     never takes the request, at `ANSWER_T` clocks and not before, word 6's
//     <2> then set; word 6's <1> the core's drain and <3> its cut, as the
//     core gives them;
//   - CYCLES then CYCLESH, TICKS then TICKSH, and VMA then Q and MD, the high
//     words and the two beside VMA of the instant the low word was read;
//   - the readout: the echo names the old address until the word is there,
//     then the asked one, and words 11 and 12 the word of that address;
//     selector 15 pulses the snapshot, once;
//   - a diagnostic register read and written at word 16 + k;
//   - BUILD, BOARDS, RANGE, VIDEO and PERIOD as the bitstream's parameters
//     give them, and RTC's start written and read back and given to the
//     machine;
//   - words 33 to 36, `cadr_console.sv`'s, with its keys and markers: the
//     display boards kept and read back; what the display output shows and
//     which way up, each key leaving the other setting alone, out to the
//     display; the lamp steady and blinking again; the sleep's setting and
//     wake each one pulse, a setting refused with a strobe off or bit 15
//     set, and the word's own read-back setting nothing; and word 42, the
//     display's two sticky bits read as the display gives them and cleared
//     by one pulse at the key alone.  A key with a strobe off, or another
//     value, changes nothing; and with no display output 36 and 42 read
//     UNMAPPED;
//   - page 3, the memory port's latency probe: word 48 the marker and the
//     probe's state, 49 to 56 its eight words each at its own place, RUN's
//     and STOP's keys each one pulse and nothing else, a key with a strobe
//     off or at another word nothing; and with no probe every word of the
//     page UNMAPPED and no key a pulse.
//
// It prints `ok:` and exits 0, or names each failure and exits 1.

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>

#include "Vquux15_face.h"
#include "verilated.h"

namespace {

Vquux15_face *d;
long ticks = 0;
int bad = 0;
long checks = 0;

// The face's parameters, as the testbench builds it (the Makefile's -G).
constexpr uint32_t kIdent = 0x434F4E53u;
constexpr uint32_t kUnmapped = ~kIdent;
constexpr uint32_t kResetKey = 0x52534554u;
constexpr int kResetT = 64;
constexpr uint32_t kBuild = 0x0E4E7450u;
constexpr long kAnswerT = 131072;  // `ANSWER_T`'s default

// The core's side of the reset (`quux15_core.sv`'s `rst_*`): a core that
// takes the request, draining `kDrain` clocks and then in its reset
// `kInReset` clocks and while the request stands; or one that never takes
// it.  `core_cut` is its sticky bit, `core_pend_force` a drain held up.
constexpr long kDrain = 40, kInReset = 64;
bool core_takes = true, core_cut = false, core_pend_force = false;
int core_state = 0;  // 0 running, 1 draining, 2 in its reset
long core_count = 0, core_left_at = -1;

void Want(const std::string &what, uint64_t got, uint64_t want) {
  ++checks;
  if (got != want) {
    ++bad;
    std::fprintf(stderr, "FAIL: %s: %#" PRIx64 ", want %#" PRIx64 " (tick %ld)\n", what.c_str(), got,
                 want, ticks);
  }
}

// The core behind the face.
uint64_t committed = 0x123456789ull, clocks = 0x0000ABCD00000000ull;
uint64_t vma = 0x1100000000ull, q = 0x2200000000ull, md = 0x3300000000ull;
std::deque<std::pair<unsigned, unsigned>> rm_pipe;  // the address, three clocks
long snaps = 0, spy_writes = 0;
unsigned last_eadr = 0, last_spy_word = 0;
// The display output behind words 34, 36 and 42: the pulses counted, the
// setting it holds as `cadr_display_out.sv` holds it, and its answers.
long sleep_sets = 0, wakes = 0, clears = 0;
// The latency probe behind page 3: its words a function of their place,
// moving every clock, and its two pulses counted.
long probe_runs = 0, probe_stops = 0;
uint32_t probe_model(unsigned k) { return 0x9B000000u + 0x01010101u * k + static_cast<uint32_t>(ticks); }
unsigned last_secs = 0, held_secs = 300;

uint64_t ro_model(unsigned sel, unsigned addr) {
  return 0xA5A5000000000000ull ^ (uint64_t(sel) << 40) ^ (uint64_t(addr) * 0x9E3779B97F4A7C15ull >> 8);
}
uint16_t spy_model(unsigned k) { return static_cast<uint16_t>(0x1000u + 0x111u * k); }

// One clock: the core's inputs set, the edge, the core's state moved.
void Step() {
  const bool req = d->mach_req;
  d->mach_pend = core_state == 1 || core_pend_force;
  d->mach_on = core_state == 2;
  d->mach_cut = core_cut;
  d->committed = committed;
  d->clocks = clocks;
  d->vma = vma;
  d->q = q;
  d->md = md;
  d->spy_rdata = spy_model(d->spy_raddr);
  const std::pair<unsigned, unsigned> head = rm_pipe.size() >= 3 ? rm_pipe[rm_pipe.size() - 3]
                                                                 : std::make_pair(0u, 0u);
  d->rm_word = ro_model(head.first, head.second);
  d->sleep_q = held_secs;
  for (unsigned k = 0; k < 8; ++k) d->probe_words[k] = probe_model(k);
  d->clk = 0;
  d->eval();
  d->clk = 1;
  d->eval();
  ++ticks;
  if (core_state == 0) {
    if (req && core_takes) {
      core_state = 1;
      core_count = 0;
    }
  } else if (core_state == 1) {
    if (++core_count >= kDrain) {
      core_state = 2;
      core_count = 0;
    }
  } else if (++core_count >= kInReset && !req) {
    core_state = 0;
    core_left_at = ticks;
  }
  // What the face gave the core this edge.
  rm_pipe.emplace_back(d->rm_sel, d->rm_addr);
  if (rm_pipe.size() > 8) rm_pipe.pop_front();
  if (d->rm_snap) ++snaps;
  if (d->sleep_set) {
    ++sleep_sets;
    last_secs = d->sleep_secs;
    held_secs = d->sleep_secs;
  }
  if (d->wake) ++wakes;
  if (d->err_clear) ++clears;
  if (d->probe_run) ++probe_runs;
  if (d->probe_stop) ++probe_stops;
  if (d->spy_we) {
    ++spy_writes;
    last_eadr = d->spy_eadr;
    last_spy_word = d->spy_wdata;
  }
  committed += 3;
  clocks += 1;
  vma += 1;
  q += 2;
  md += 5;
}

int Write(unsigned word, uint32_t data, unsigned strb = 0xF, long limit = 64) {
  d->s_awaddr = (word * 4u) & 0xFFFu;
  d->s_awlen = 0;
  d->s_awid = 5;
  d->s_awvalid = 1;
  d->s_wdata = data;
  d->s_wstrb = strb;
  d->s_wlast = 1;
  d->s_wvalid = 1;
  d->s_bready = 1;
  bool aw = false, w = false;
  for (long k = 0; k < limit; ++k) {
    d->eval();
    const bool aw_now = d->s_awvalid && d->s_awready;
    const bool w_now = d->s_wvalid && d->s_wready;
    const bool b_now = d->s_bvalid && d->s_bready;
    const int resp = d->s_bresp;
    Step();
    if (aw_now) {
      aw = true;
      d->s_awvalid = 0;
    }
    if (w_now) {
      w = true;
      d->s_wvalid = 0;
    }
    if (b_now && aw && w) {
      d->s_bready = 0;
      return resp;
    }
  }
  Want("a write answered at word " + std::to_string(word), 0, 1);
  return -1;
}

uint32_t Read(unsigned word) {
  d->s_araddr = (word * 4u) & 0xFFFu;
  d->s_arlen = 0;
  d->s_arid = 3;
  d->s_arvalid = 1;
  d->s_rready = 1;
  for (int k = 0; k < 64; ++k) {
    d->eval();
    const bool ar_now = d->s_arvalid && d->s_arready;
    const bool r_now = d->s_rvalid && d->s_rready;
    const uint32_t data = d->s_rdata;
    const int resp = d->s_rresp;
    Step();
    if (ar_now) d->s_arvalid = 0;
    if (r_now) {
      d->s_rready = 0;
      Want("RRESP at word " + std::to_string(word), resp, 0);
      return data;
    }
  }
  Want("a read answered at word " + std::to_string(word), 0, 1);
  return 0;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vquux15_face;
  d->build = kBuild;
  d->disp_fitted = 1;
  d->probe_fitted = 0;
  d->asleep = 0;
  d->underrun = 0;
  d->rd_error = 0;
  d->rst = 1;
  for (int k = 0; k < 4; ++k) Step();
  d->rst = 0;
  Step();

  // ---- what it is, and what it is not
  Want("IDENT", Read(0), kIdent);
  for (unsigned w : {13u, 14u, 15u, 43u, 47u, 63u, 100u, 1023u})
    Want("word " + std::to_string(w) + ", which the face does not name", Read(w), kUnmapped);

  // ---- the reset: none from power-on, a request at the key alone
  Want("no reset asked for from power-on", d->mach_req, 0);
  Want("STAT answered, no switch", Read(1), 0x04u);
  Write(6, kResetKey ^ 1u);
  for (int k = 0; k < 4; ++k) Step();
  Want("a value not the key asks for nothing", d->mach_req, 0);
  Write(6, kResetKey, 0x7u);
  for (int k = 0; k < 4; ++k) Step();
  Want("the key with a strobe off asks for nothing", d->mach_req, 0);
  Want("RESET reads the key's half and no reset", Read(6), (kResetKey & 0xFFFF0000u));
  {
    // The answer once the core is through its reset: after the drain and
    // the reset, a few clocks after the core leaves it.
    const long w0 = ticks;
    core_left_at = -1;
    Write(6, kResetKey, 0xF, 4000);
    const long b_at = ticks;
    ++checks;
    if (core_left_at < 0 || b_at < core_left_at || b_at > core_left_at + 4) {
      ++bad;
      std::fprintf(stderr, "FAIL: the RESET write answered %ld clocks after it, the core out of its reset at %ld\n",
                   b_at - w0, core_left_at < 0 ? -1 : core_left_at - w0);
    }
    Want("the request over by the answer", d->mach_req, 0);
  }
  Want("STAT after the reset", Read(1), 0x04u);
  Want("RESET's count", Read(6), (kResetKey & 0xFFFF0000u) | (1u << 8));
  // The core's drain and its cut, in word 6.
  core_pend_force = true;
  Step();
  Want("RESET with the core draining", Read(6), (kResetKey & 0xFFFF0000u) | (1u << 8) | 0x3u);
  core_pend_force = false;
  core_cut = true;
  Step();
  Want("RESET with the port cut", Read(6), (kResetKey & 0xFFFF0000u) | (1u << 8) | 0x8u);
  core_cut = false;
  {
    // A core that never takes the request: the answer at the bound.
    core_takes = false;
    const long w0 = ticks;
    Write(6, kResetKey, 0xF, kAnswerT + 100);
    const long lat = ticks - w0;
    ++checks;
    if (lat < kAnswerT || lat > kAnswerT + 8) {
      ++bad;
      std::fprintf(stderr, "FAIL: with the core not taking it the RESET write answered %ld clocks after it, "
                   "wanting %ld\n", lat, kAnswerT);
    }
    Want("RESET after an answer at the bound", Read(6), (kResetKey & 0xFFFF0000u) | (2u << 8) | 0x4u);
    core_takes = true;
  }

  // ---- the counters: the high word of the low word's instant
  {
    const uint64_t c0 = committed;
    const uint32_t lo = Read(2);
    for (int k = 0; k < 7; ++k) Step();
    const uint32_t hi = Read(3);
    const uint64_t got = (uint64_t(hi) << 32) | lo;
    ++checks;
    if (got < c0 || got > c0 + 3 * 8) {
      ++bad;
      std::fprintf(stderr, "FAIL: CYCLES %#" PRIx64 " not of its read's instant, %#" PRIx64 "\n", got, c0);
    }
    committed = 0x00000001FFFFFFF0ull;  // a carry between the two reads
    const uint32_t lo2 = Read(2);
    for (int k = 0; k < 20; ++k) Step();
    const uint32_t hi2 = Read(3);
    Want("CYCLESH across a carry, the low word's", hi2, lo2 >= 0xFFFFFFF0u ? 1u : 2u);
    const uint64_t t0 = clocks;
    const uint32_t tlo = Read(4);
    const uint32_t thi = Read(5);
    Want("TICKSH", thi, uint32_t(t0 >> 32));
    ++checks;
    if (tlo < uint32_t(t0)) {
      ++bad;
      std::fprintf(stderr, "FAIL: TICKS %#x before its read\n", tlo);
    }
  }

  // ---- VMA, then Q and MD of the same instant
  {
    const uint32_t v = Read(7);
    for (int k = 0; k < 5; ++k) Step();
    const uint32_t qq = Read(8), mm = Read(9);
    // The three move together: VMA by 1, Q by 2 and MD by 5 a clock, so the
    // instant VMA was read at names Q and MD.
    const uint64_t at = uint64_t(v) - uint32_t(0x1100000000ull);
    Want("Q beside VMA", qq, uint32_t(0x2200000000ull + 2 * at));
    Want("MD beside VMA", mm, uint32_t(0x3300000000ull + 5 * at));
  }

  // ---- the readout: the echo moves when the word is there
  {
    const unsigned sel = 4, addr = 0x2CEC;
    const uint32_t asked = (sel << 14) | addr;
    Write(10, asked);
    // Read at once: the face takes the address and its word some clocks on.
    unsigned tries = 0;
    uint32_t echo = Read(10);
    while (echo != asked && tries < 32) {
      Want("an echo before the word: the old address", echo, 0x3FFFFu);
      echo = Read(10);
      ++tries;
    }
    Want("the echo", echo, asked);
    const uint64_t word = uint64_t(Read(11)) | (uint64_t(Read(12)) << 32);
    Want("the readout's word, both halves", word, ro_model(sel, addr));
    // Another address, the echo moving to it.
    const uint32_t asked2 = (13u << 14) | 0x3FFu;
    Write(10, asked2);
    for (int k = 0; k < 16; ++k) Step();
    Want("the second echo", Read(10), asked2);
    Want("its low half", Read(11), uint32_t(ro_model(13, 0x3FF)));
    Want("its high half", Read(12), uint32_t(ro_model(13, 0x3FF) >> 32));
    // A read of 11 alone gives the last echo's word.
    for (int k = 0; k < 9; ++k) Step();
    Want("word 11 read alone, the latch's", Read(11), uint32_t(ro_model(13, 0x3FF)));
    // The snapshot: selector 15, one pulse.
    snaps = 0;
    Write(10, 15u << 14);
    for (int k = 0; k < 16; ++k) Step();
    Want("selector 15's snapshot, one pulse", snaps, 1);
    Write(10, (2u << 14) | 7u);
    for (int k = 0; k < 16; ++k) Step();
    Want("another selector takes no snapshot", snaps, 1);
  }

  // ---- the diagnostic registers
  for (unsigned k = 0; k < 16; ++k)
    Want("diagnostic register " + std::to_string(k), Read(16 + k), spy_model(k));
  spy_writes = 0;
  Write(16 + 5, 0xABCD1234u);
  Want("a register written once", spy_writes, 1);
  Want("its EADR", last_eadr, 5);
  Want("its word", last_spy_word, 0x1234);
  Write(16 + 3, 0x0000FFFFu);
  Want("register 3 written", last_eadr, 3);

  // ---- what the bitstream is
  Want("BUILD", Read(32), kBuild);
  Want("BOARDS", Read(37), (0x4244u << 16) | 32u);
  Want("RANGE", Read(38), (0x1A5u << 22) | (32u << 11) | 32u);
  Want("VIDEO", Read(39), (0x356u << 22) | (1280u << 11) | 1024u);
  Want("PERIOD", Read(40), 34u);
  Write(37, (0x4D42u << 16) | 64u);
  Want("BOARDS refuses a write", Read(37), (0x4244u << 16) | 32u);
  Write(41, 0x6AB30C91u);
  Want("RTC's start read back", Read(41), 0x6AB30C91u);
  Want("RTC's start given to the machine", d->rtc_start, 0x6AB30C91u);
  Write(41, 0x00000000u, 0x1u);
  Want("RTC's start, one byte written", Read(41), 0x6AB30C00u);

  // ---- words 33 to 36 and 42: the display output and the lamp
  {
    constexpr uint32_t kSimple = 0x534D504Cu, kLispm = 0x4C53504Du, kColor = 0x434F4C52u;
    constexpr uint32_t kTvMark = 0x5456u << 16;
    Want("33 out of reset: one SIMPLE TV, no color board", Read(33), kTvMark);
    Write(33, kLispm);
    Want("33 after LSPM", Read(33), kTvMark | 1u);
    Write(33, kColor);
    Want("33 after COLR, the first board kept", Read(33), kTvMark | 3u);
    Write(33, kSimple, 0xEu);
    Want("33: SMPL with a strobe off changes nothing", Read(33), kTvMark | 3u);
    Write(33, kSimple);
    Want("33 after SMPL", Read(33), kTvMark | 2u);
    Write(33, ~kColor);
    Want("33 after COLR's complement", Read(33), kTvMark);
    Write(33, kTvMark | 3u);
    Want("33: its own read-back written changes nothing", Read(33), kTvMark);

    constexpr uint32_t kTv = 0x48545631u, kCol = 0x48545632u, kBoth = 0x48545642u;
    constexpr uint32_t kUp = 0x48555052u, kCw = 0x48524357u, kCcw = 0x48524343u;
    constexpr uint32_t kHdMark = 0x4844u << 16;
    Want("34 out of reset: the first display, upright", Read(34), kHdMark | 1u);
    Want("the display shown out of reset", d->disp_out, 1);
    Want("the display upright out of reset", d->disp_rotate, 0);
    Write(34, kBoth);
    Want("34 after both", Read(34), kHdMark | 3u);
    Want("both to the display", d->disp_out, 3);
    Write(34, kCw);
    Want("34 after clockwise, both kept", Read(34), kHdMark | (1u << 2) | 3u);
    Want("clockwise to the display", d->disp_rotate, 1);
    Write(34, kCol);
    Want("34 after the color board, the turn kept", Read(34), kHdMark | (1u << 2) | 2u);
    Write(34, kCcw);
    Want("34 after anticlockwise", Read(34), kHdMark | (2u << 2) | 2u);
    Want("anticlockwise to the display", d->disp_rotate, 2);
    Write(34, kTv, 0x7u);
    Want("34: a key with a strobe off changes nothing", Read(34), kHdMark | (2u << 2) | 2u);
    Write(34, kTv);
    Write(34, kUp);
    Want("34 after the first display, upright", Read(34), kHdMark | 1u);
    Want("the first display to the display", d->disp_out, 1);
    Want("upright to the display", d->disp_rotate, 0);

    constexpr uint32_t kSteady = 0x53544459u, kLampMark = 0x4C44u << 16;
    Want("35 out of reset: blinking", Read(35), kLampMark);
    Want("the lamp blinking out of reset", d->steady_lamps, 0);
    Write(35, kSteady, 0xBu);
    Want("35: STDY with a strobe off changes nothing", Read(35), kLampMark);
    Write(35, kSteady);
    Want("35 after STDY", Read(35), kLampMark | 1u);
    Want("the lamp steady", d->steady_lamps, 1);
    Write(35, ~kSteady);
    Want("35 after its complement", Read(35), kLampMark);
    Want("the lamp blinking again", d->steady_lamps, 0);

    constexpr uint32_t kSleepKey = 0x4853u << 16;
    constexpr uint32_t kWakeKey = 0x57414B45u, kZz = 0x5A5Au << 16;
    Want("36 out of reset: awake, the display's own 300 s", Read(36), kZz | 300u);
    Write(36, kSleepKey | 5u);
    Want("a setting, one pulse", sleep_sets, 1);
    Want("its seconds", last_secs, 5);
    Want("36 reads what the display holds", Read(36), kZz | 5u);
    Write(36, kSleepKey | 7u, 0xEu);
    Want("a setting with a strobe off: no pulse", sleep_sets, 1);
    Write(36, kSleepKey | 0x8000u | 7u);
    Want("a setting with bit 15 set: no pulse", sleep_sets, 1);
    Write(36, kZz | 5u);
    Want("36's own read-back written: no setting", sleep_sets, 1);
    Want("36's own read-back written: no wake", wakes, 0);
    Write(36, kWakeKey);
    Want("a wake, one pulse", wakes, 1);
    Want("a wake sets nothing", sleep_sets, 1);
    Write(36, kWakeKey, 0x7u);
    Want("a wake with a strobe off: no pulse", wakes, 1);
    d->asleep = 1;
    Want("36 with the display asleep", Read(36), kZz | 0x8000u | 5u);
    d->asleep = 0;

    constexpr uint32_t kClear = 0x434C5244u, kDeMark = 0x4445u << 16;
    Want("42 with nothing raised", Read(42), kDeMark);
    d->underrun = 1;
    Want("42 with an underrun", Read(42), kDeMark | 1u);
    d->rd_error = 1;
    Want("42 with both", Read(42), kDeMark | 3u);
    d->underrun = 0;
    Want("42 with a read error", Read(42), kDeMark | 2u);
    Write(42, kClear, 0x7u);
    Want("the clear with a strobe off: no pulse", clears, 0);
    Write(42, kClear ^ 0x100u);
    Want("another value: no pulse", clears, 0);
    Write(42, kDeMark | 3u);
    Want("42's own read-back written: no pulse", clears, 0);
    Write(42, kClear);
    Want("the clear, one pulse", clears, 1);
    d->rd_error = 0;
    Want("no word but 34 and 36 asks the display for anything", sleep_sets + wakes, 2);

    d->disp_fitted = 0;
    Want("36 with no display output", Read(36), kUnmapped);
    Want("42 with no display output", Read(42), kUnmapped);
    d->disp_fitted = 1;
  }

  // ---- page 3: the memory port's latency probe
  {
    constexpr uint32_t kRun = 0x5052554Eu, kStop = 0x53544F50u, kPbMark = 0x5042u << 16;
    d->probe_fitted = 0;
    d->probe_state = 5;
    for (unsigned w = 48; w <= 56; ++w) Want("page 3 with no probe, word " + std::to_string(w), Read(w), kUnmapped);
    Write(48, kRun);
    Write(48, kStop);
    Want("RUN and STOP with no probe: no pulse", probe_runs + probe_stops, 0);
    d->probe_fitted = 1;
    Want("47 beside the probe", Read(47), kUnmapped);
    Want("57 beside the probe", Read(57), kUnmapped);
    Want("48 with the probe lost and running", Read(48), kPbMark | 5u);
    d->probe_state = 2;
    Want("48 with the probe saturated", Read(48), kPbMark | 2u);
    // Each word read is the probe's at the clock the face sampled it; the
    // model moves a step a clock, so the word must be its own place's
    // within the read's few clocks.
    for (unsigned w = 49; w <= 56; ++w) {
      const long before = ticks;
      const uint32_t got = Read(w);
      const uint32_t base = 0x9B000000u + 0x01010101u * (w - 49);
      const bool ok = got - base >= static_cast<uint32_t>(before) && got - base <= static_cast<uint32_t>(ticks);
      Want("word " + std::to_string(w) + " is the probe's word " + std::to_string(w - 49), ok, 1);
    }
    Write(48, kRun, 0x7u);
    Write(48, kRun ^ 0x100u);
    Write(48, kPbMark | 2u);
    Write(49, kRun);
    Write(47, kStop);
    Want("a key with a strobe off, another value, the read-back or another word: no pulse",
         probe_runs + probe_stops, 0);
    Write(48, kRun);
    Want("RUN, one pulse", probe_runs, 1);
    Want("RUN is not STOP", probe_stops, 0);
    Write(48, kStop);
    Want("STOP, one pulse", probe_stops, 1);
    Want("STOP is not RUN", probe_runs, 1);
    d->probe_state = 0;
  }

  d->final();
  delete d;
  if (bad) {
    std::fprintf(stderr, "FAIL: %d of %ld checks of quux15_face\n", bad, checks);
    return 1;
  }
  std::printf("ok: quux15_face, %ld checks: its words, the reset, the latches, the readout's echo, "
              "the diagnostic registers, the bitstream's words, words 33 to 36 and 42, and the probe's page\n", checks);
  return 0;
}
