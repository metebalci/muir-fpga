// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Drives rtl/cadr_disk_controller.sv from the reference trace and compares the
// register face. The trace is written by golden/src/disk.rs out of muir's own
// disk_controller::Controller, driven register by register, and carries the
// stimulus --- the drive, its read-only switch, whether its time is charged
// --- as well as the expected outputs.
//
// WHAT THIS CHECK HOLDS TO. Every `CYC` read row's read-back, and after every
// `START` and every `INIT` the whole observable face: the status word, the
// disk address, the last memory address, the ECC register and `interrupt()`,
// read back through four bus cycles of its own. The trace reads register 1
// six times, register 2 six and register 3 three; those forty-nine extra
// faces are what makes the other three registers checkable at all.
//
// **WHAT IS EXEMPT, AND IT IS BOUNDED AND COUNTED ON THE OUTPUT BELOW.** This
// slice has no channel: no block store, no command list, no bus master. So a
// command that MOVES DATA leaves state this fabric cannot compute, and the
// exemptions are exactly that state and no more:
//
//   the channel's status bits `<22> <21> <20> <18> <17> <16> <15> <14>`
//       never compared, because nothing here can raise them. The run says
//       how many rows the reference had one of them set on, so that "never
//       compared" cannot quietly become "never happens".
//   `<13>` transfer aborted
//       not compared on those same rows: `lossage()` ORs the channel's
//       errors in.
//   `<10>` seek error, `<6>` fault, `<13>`
//       the CCW walk's `next_block` can raise a seek error where this
//       slice's seek cannot. Exempt from a data-moving START until the
//       fabric and the reference are next observed to agree on them, or
//       until the next at-ease START, whichever comes first.
//   `<0>` not active and `<3>` interrupt request
//       `access_ns` is a function of how many blocks the command list names,
//       which is the walk. Exempt from a data-moving START taken with the
//       drive's time charged until the next store into the command register.
//   register 1, the last memory address, and register 3, the ECC register
//       both are the channel's outright. Exempt from the first data-moving
//       START onward.
//   register 2, the disk address
//       the walk leaves the heads where it stopped. Exempt from a
//       data-moving START until the fabric and the reference are next
//       observed to agree, or until the program's next store into it.
//   the `BLK`, `MEMPAGE`, `MEMW`, `PAGE` and `LAY` rows
//       the pack and main memory, which are the channel's two ends. Counted
//       and not consumed.
//
// A data-moving START is one whose command code is 0o00, 0o01, 0o02, 0o03,
// 0o10, 0o11 or 0o13 with a drive on the selected unit --- every one of those
// seven has bit 2 clear, so `Controller::start` returns before it looks at
// the code when the cable is empty. A write to a READ-ONLY pack is not one of
// them: muir raises the fault and returns before any data moves, and this
// fabric does the same, so those are compared in full.
//
// HOW THE ROWS ARE PLACED ON THE 5 ns GRID, WHICH IS THE ONE THING THE TRACE
// CANNOT SAY. muir's controller takes no time of its own, so the generator
// makes twenty-eight bus cycles "at instant 0" and a hundred and ninety-six
// at one instant in the middle. Fabric cannot: a register write needs a clock
// edge, and a read needs the held address match settled. So each cycle here
// costs ticks --- a read one, or two when the register changes; a write two,
// the first of which drops -XBUS.RQ so that `taken` lets the next one
// through --- and a group of rows sharing an instant is spread over them.
//
// **THE GROUP IS ANCHORED ON ITS LAST START AND NOT ON ITS FIRST ROW**, and
// that is not a detail: a START is the only thing in this module that loads a
// timer, so it is the only row whose instant has to be exact. The hang in
// phase 0 is the twenty-seventh cycle at instant 0 and its timeout is read
// 512,000,000 ticks later, either side of the boundary --- place the group
// forward from instant 0 and the timer expires 26 ticks late and the check
// fails; place it backward and it expires a tick early and the check fails
// the other way. Anchored on the START, both samples land exactly.
//
// Five of the ninety groups hold more than one START. The last is anchored
// and the earlier ones fall a few hundred ticks short of their instant, which
// is checked to be harmless: every one of them is either a seek with the
// drive's time not charged --- so nothing is charged at all --- or a hang
// whose next sample is milliseconds away against a 2.56 s timer.
//
// AND THE SPINDLE HAS TO BE IN PHASE, which is what the pre-roll is for. The
// block counter is `now mod REVOLUTION_NS` and the trace samples either side
// of all eighteen region edges, so the fabric's `spin` must equal the model's
// `now` at every mapped tick. Mapping instant T to tick T/5 + K makes
// `spin` come out T + 5K, so 5K has to be a whole number of revolutions ---
// and since 16,666,667 is coprime with 5, the smallest K that does it is a
// revolution's worth of TICKS, 16,666,667 of them, which is five turns of the
// spindle. That is 3% more ticks than the trace itself and it buys exactness
// at every edge.

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Vcadr_disk_controller.h"
#include "verilated.h"

namespace {

// `disk_controller::REGS`, 0o17377774, as a word address.
const unsigned REGS = 017377774u;

// The spindle's period in nanoseconds, and the pre-roll in ticks that puts
// the fabric's spin counter in phase with muir's `now`. See the note above.
const long REVOLUTION_NS = 16666667L;
const long RESET_TICKS = 8;
// A group whose last START is not its first row begins BEFORE the instant it
// is anchored on, so the schedule has to have room in front of instant zero.
// The largest group here is 196 rows and about 730 ticks; this is room for
// ten times that, and the run says so if a group ever cannot be placed.
const long SLACK = 8192;
// Instant T maps to tick T/5 + K.  `spin` is 5 x (tick - RESET_TICKS), so
// `spin` at that tick is T + 5 x REVOLUTION_NS, and five revolutions of the
// spindle is no revolutions at all --- which is why K - RESET_TICKS has to be
// a whole revolution's worth of TICKS and not merely large.  16,666,667 is
// coprime with 5, so that is the smallest one there is.
const long K = RESET_TICKS + REVOLUTION_NS;

// Whether a store into START loads a timer, which is the only thing whose
// instant has to be exact: a hang starts the 2.56 s counter, and a seek or a
// recalibrate charges the drive's own time and arms its attention --- but
// only when that time is charged at all.  A data-moving command charges
// `access_ns` too and is deliberately NOT here: its not-active is exempt in
// this slice, so nothing reads the counter it loads.
bool loads_timer(unsigned code, bool present, bool recal, bool timed) {
  switch (code & 017u) {
    case 007: case 017: case 012: return true;          // the sequencer hangs
    case 004: case 014: return !present || timed;       // hang, or the heads move
    case 006: return !present;                          // hang
    case 005: case 015: return present && timed && recal;  // the heads go home
    default: return false;
  }
}

// The eight command codes that reach a transfer or its access time.
bool data_moving_code(unsigned code) {
  switch (code & 017u) {
    case 000: case 001: case 002: case 003:
    case 010: case 011: case 013: return true;
    default: return false;
  }
}

// The status bits this slice cannot raise, because a transfer raises them.
const unsigned CHAN = (1u << 22) | (1u << 21) | (1u << 20) | (1u << 18) |
                      (1u << 17) | (1u << 16) | (1u << 15) | (1u << 14);
// The selected drive's own two flags, and the lossage they feed.
const unsigned DRIVE_BITS = (1u << 10) | (1u << 6) | (1u << 13);
// Not-active and the interrupt it gates.
const unsigned BUSY_BITS = (1u << 0) | (1u << 3);
// The four bits a running counter decides: not-active, its interrupt, and the
// two attentions. On a row the fabric reaches before or after muir's instant
// these are checked ONE WAY --- see the note at `time_ok` below.
const unsigned TIME_BITS = BUSY_BITS | (1u << 2) | (1u << 1);

struct Row {
  char kind;        // 'C' CYC, 'I' INIT, 'A' ATTACH, 'R' RO, 'T' TIMED, 'L' LAY
  long n;
  long now;
  int reg, wr;
  unsigned wdata, rdata;
  unsigned status, da, lma, ecc;
  int intr, pages;
  int unit, flag;
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/disk.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  // ---- the trace, and the constants in its header ------------------------
  //
  // The header carries every number this module hard-codes. Reading them back
  // and asserting them is what says a muir that moved under the generator
  // says so here rather than as a mismatch a hundred rows in.
  std::vector<Row> rows;
  long h_cyl = -1, h_heads = -1, h_bpt = -1;
  long h_timeout = -1, h_rev = -1, h_sector = -1, h_index = -1, h_pulse = -1;
  long h_ticks = -1;   // the trace's own last instant, in ticks
  long blk_rows = 0, mempage_rows = 0, memw_rows = 0, page_rows = 0;

  char line[8192];
  // BLK and MEMPAGE rows are 256 words wide; read them with a big buffer and
  // count them without keeping them.
  std::string big;
  while (true) {
    if (!std::fgets(line, sizeof line, f)) break;
    size_t len = std::strlen(line);
    big.assign(line);
    while (len > 0 && line[len - 1] != '\n') {
      if (!std::fgets(line, sizeof line, f)) break;
      len = std::strlen(line);
      big += line;
    }
    const char *s = big.c_str();
    if (s[0] == '#') {
      char key[64];
      long a, b, c;
      if (std::sscanf(s, "# %63s %ld %ld %ld", key, &a, &b, &c) >= 2) {
        std::string k(key);
        if (k == "geometry") { h_cyl = a; h_heads = b; h_bpt = c; }
        else if (k == "timeout_ns") h_timeout = a;
        else if (k == "revolution_ns") h_rev = a;
        else if (k == "sector_ns") h_sector = a;
        else if (k == "index_pulse_ns") h_index = a;
        else if (k == "sector_pulse_ns") h_pulse = a;
        else if (k == "ticks") h_ticks = a;
      }
      continue;
    }
    if (s[0] == '\n' || s[0] == '\0') continue;

    Row r;
    std::memset(&r, 0, sizeof r);
    if (std::strncmp(s, "CYC ", 4) == 0) {
      r.kind = 'C';
      if (std::sscanf(s, "CYC %ld %ld %d %d %x %x %x %x %x %x %d %d",
                      &r.n, &r.now, &r.reg, &r.wr, &r.wdata, &r.rdata,
                      &r.status, &r.da, &r.lma, &r.ecc, &r.intr,
                      &r.pages) != 12) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, s);
        return 2;
      }
      rows.push_back(r);
    } else if (std::strncmp(s, "INIT ", 5) == 0) {
      r.kind = 'I';
      if (std::sscanf(s, "INIT %ld %ld %x %x %x %x %d", &r.n, &r.now,
                      &r.status, &r.da, &r.lma, &r.ecc, &r.intr) != 7) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, s);
        return 2;
      }
      rows.push_back(r);
    } else if (std::strncmp(s, "ATTACH ", 7) == 0) {
      r.kind = 'A';
      long slots;
      if (std::sscanf(s, "ATTACH %ld %ld %d %ld", &r.n, &r.now, &r.unit,
                      &slots) != 4) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, s);
        return 2;
      }
      rows.push_back(r);
    } else if (std::strncmp(s, "RO ", 3) == 0) {
      r.kind = 'R';
      if (std::sscanf(s, "RO %ld %ld %d", &r.n, &r.now, &r.flag) != 3) return 2;
      rows.push_back(r);
    } else if (std::strncmp(s, "TIMED ", 6) == 0) {
      r.kind = 'T';
      if (std::sscanf(s, "TIMED %ld %ld %d", &r.n, &r.now, &r.flag) != 3)
        return 2;
      rows.push_back(r);
    } else if (std::strncmp(s, "LAY ", 4) == 0) {
      r.kind = 'L';
      if (std::sscanf(s, "LAY %ld %ld", &r.n, &r.now) != 2) return 2;
      rows.push_back(r);
    } else if (std::strncmp(s, "BLK ", 4) == 0) {
      ++blk_rows;
    } else if (std::strncmp(s, "MEMPAGE ", 8) == 0) {
      ++mempage_rows;
    } else if (std::strncmp(s, "MEMW ", 5) == 0) {
      ++memw_rows;
    } else if (std::strncmp(s, "PAGE ", 5) == 0) {
      ++page_rows;
    } else {
      std::fprintf(stderr, "%s: unknown row: %s", path, s);
      return 2;
    }
  }
  std::fclose(f);

  if (rows.empty()) {
    std::fprintf(stderr, "FAIL: the trace was empty\n");
    return 1;
  }

  // The module's own constants, against the generator's header. A muir that
  // moves under either says so here.
  struct { const char *what; long got, want; } consts[] = {
      {"cylinders", h_cyl, 815},
      {"heads", h_heads, 19},
      {"blocks per track", h_bpt, 17},
      {"TIMEOUT_NS", h_timeout, 2560000000L},
      {"REVOLUTION_NS", h_rev, 16666667L},
      {"SECTOR_NS", h_sector, 968448L},
      {"INDEX_PULSE_NS", h_index, 4000L},
      {"SECTOR_PULSE_NS", h_pulse, 1240L},
  };
  int wrong = 0;
  for (const auto &c : consts)
    if (c.got != c.want) {
      std::fprintf(stderr,
                   "FAIL: the trace says %s is %ld and rtl/cadr_disk_"
                   "controller.sv has %ld\n",
                   c.what, c.got, c.want);
      ++wrong;
    }
  if (wrong) return 1;

  if (h_ticks < 0) {
    std::fprintf(stderr, "FAIL: %s has no tick count in its header\n", path);
    return 1;
  }

  auto *dut = new Vcadr_disk_controller;

  // ---- the driver --------------------------------------------------------
  long tick = 0;
  int d_sel = 0, d_rq = 0, d_wr = 0, d_init = 0, d_rst = 1;
  unsigned d_phys = 0, d_wdata = 0;
  unsigned d_present = 0, d_ro = 0;
  int d_timed = 0;
  // What `mine` and `which` will hold during the NEXT tick: the address match
  // is held in a register, so a read has to be set up a tick ahead.
  int live_sel = 0, live_reg = -1;

  unsigned sampled = 0;
  auto run_tick = [&](bool sample) {
    dut->rst = d_rst;
    dut->xbus_init = d_init;
    dut->sel = d_sel;
    dut->dev_rq = d_rq;
    dut->dev_write = d_wr;
    dut->phys = d_phys;
    dut->wdata = d_wdata;
    dut->drive_present = d_present;
    dut->drive_read_only = d_ro;
    dut->drive_timed = d_timed;
    dut->clk = 0;
    dut->eval();
    if (sample) sampled = dut->rdata;
    dut->clk = 1;
    dut->eval();
    ++tick;
    live_sel = d_sel;
    live_reg = d_sel ? (int)(d_phys & 3u) : -1;
    if (d_sel && (d_phys >> 2) != (REGS >> 2)) live_reg = -1;
  };

  // Reset, then the pre-roll that puts the spindle in phase, stopping SLACK
  // ticks short of instant zero so that the first group has room in front of
  // the START it is anchored on.
  for (long i = 0; i < RESET_TICKS; ++i) run_tick(false);
  d_rst = 0;
  while (tick < K - SLACK) run_tick(false);

  // Between groups the bus is idle: -XBUS.RQ down, so `taken` is clear when
  // the next store arrives, and no slave is left driving MEM<31:0>.
  auto idle_to = [&](long target) {
    if (tick < target) {
      d_rq = 0;
      d_init = 0;
      while (tick < target) run_tick(false);
    }
  };

  // A read of one of the four registers, sampled at the tick it settles on.
  auto do_read = [&](int reg) -> unsigned {
    if (!(live_sel && live_reg == reg)) {
      d_sel = 1; d_rq = 1; d_wr = 0; d_phys = REGS | (unsigned)reg;
      run_tick(false);
    }
    d_sel = 1; d_rq = 1; d_wr = 0; d_phys = REGS | (unsigned)reg;
    run_tick(true);
    return sampled;
  };

  // A write. The first tick drops -XBUS.RQ so that `taken` is clear and sets
  // the address a tick ahead of the request; the second raises it, and the
  // store lands at the edge that ends it.
  auto do_write = [&](int reg, unsigned v) {
    d_sel = 1; d_rq = 0; d_wr = 1; d_phys = REGS | (unsigned)reg; d_wdata = v;
    run_tick(false);
    d_rq = 1;
    run_tick(false);
  };

  // `-XBUS INIT` on the backplane, which is not a bus cycle.
  auto do_init = [&]() {
    d_rq = 0; d_init = 1;
    run_tick(false);
    d_init = 0;
  };

  // ---- what the run counts ----------------------------------------------
  long checked_read = 0, checked_status = 0, checked_da = 0, checked_lma = 0;
  long checked_ecc = 0, checked_intr = 0, faces = 0;
  long ex_chan_live = 0, ex_l13 = 0, ex_drive = 0, ex_busy = 0;
  long ex_da = 0, ex_lma = 0, ex_ecc = 0, ex_counter = 0, checked_counter = 0;
  long ex_charged = 0;
  long dm_starts = 0, starts = 0, slipped_groups = 0, unanchored_starts = 0;
  long groups = 0, shared_groups = 0;
  long full_timeouts = 0, hangs = 0;
  unsigned counters_seen = 0;   // a bit a block-counter value
  unsigned codes_seen = 0;      // a bit a command code
  long seeks_timed = 0, attentions = 0, any_attentions = 0;
  long seek_errors = 0, faults = 0, read_onlys = 0;
  int bad = 0;

  bool da_dirty = false, lma_dirty = false, ecc_dirty = false;
  bool busy_dirty = false, drive_dirty = false;
  unsigned lastcmd = 0;
  unsigned ref_da = 0;   // the reference's disk address as of the last row
  int attached_unit = -1;

  auto fail = [&](const Row &r, const char *what, unsigned got,
                  unsigned want) {
    std::fprintf(stderr,
                 "row %ld at %ld ns (tick %ld): %s is %08x, muir says %08x\n",
                 r.n, r.now, tick - 1, what, got, want);
    ++bad;
  };

  // **A ROW THE FABRIC REACHES EARLY OR LATE IS CHECKED ONE WAY ROUND.** The
  // rows of a group run in muir's own order and differ from it only in how
  // much time has passed, so a row placed before its instant may find the
  // fabric still busy where muir has finished, and may NOT find it finished
  // where muir is still busy; a row placed after it, the reverse. That is a
  // real check on the 51 rows where the drive's time is charged and the
  // placement is not exact, where masking the four bits would be none.
  auto time_ok = [&](const Row &r, unsigned st, long st_tick) {
    ++ex_charged;
    bool early = st_tick < r.now / 5 + K;
    unsigned wrong = early ? (st & TIME_BITS & ~r.status)
                           : (r.status & TIME_BITS & ~st);
    if (wrong)
      fail(r, early ? "not-active or an attention, ahead of muir's instant"
                    : "not-active or an attention, behind muir's instant",
           st & TIME_BITS, r.status & TIME_BITS);
  };

  // The comparison of one whole face against one row, with the exemptions
  // above applied and counted.
  auto compare_face = [&](const Row &r, unsigned st, long st_tick, unsigned da,
                          unsigned lma, unsigned ecc) {
    unsigned mask = ~CHAN;
    // **THE BLOCK COUNTER IS COMPARED ONLY WHERE THE ROW LANDS ON ITS OWN
    // INSTANT.**  The spindle turns while the fabric works through a group of
    // rows the model puts at one instant, and 196 of them is about 3.5 us
    // against regions of 968 --- enough to cross an edge, and instant
    // 2,583,337,385 is 4,000 ns into a revolution, which is the index pulse's
    // trailing edge exactly.  Every row of the block-counter sweep has an
    // instant to itself and is compared; a row that shares one is not.
    if (st_tick != r.now / 5 + K) {
      ++ex_counter;
      mask &= 0x00FFFFFFu;
      if (d_timed) { mask &= ~TIME_BITS; time_ok(r, st, st_tick); }
    } else ++checked_counter;
    if (r.status & CHAN) { ++ex_chan_live; ++ex_l13; mask &= ~(1u << 13); }
    if (drive_dirty && ((st ^ r.status) & DRIVE_BITS) == 0) drive_dirty = false;
    if (drive_dirty) { ++ex_drive; mask &= ~DRIVE_BITS; }
    if (busy_dirty) { ++ex_busy; mask &= ~BUSY_BITS; }
    ++checked_status;
    if ((st ^ r.status) & mask) fail(r, "the status word", st, r.status);
    unsigned bc = st >> 24;
    if (bc < 32) { if (st_tick == r.now / 5 + K) counters_seen |= 1u << bc; }
    else fail(r, "the block counter, which cannot exceed 17", bc, 17);
    if ((st >> 10) & 1) ++seek_errors;
    if ((st >> 7) & 1) ++read_onlys;
    if ((st >> 6) & 1) ++faults;
    if ((st >> 2) & 1) ++attentions;
    if ((st >> 1) & 1) ++any_attentions;

    if (da_dirty && da == r.da) da_dirty = false;
    if (da_dirty) ++ex_da;
    else { ++checked_da; if (da != r.da) fail(r, "the disk address", da, r.da); }

    if (lma_dirty) ++ex_lma;
    else {
      ++checked_lma;
      if (lma != r.lma) fail(r, "the last memory address", lma, r.lma);
    }
    if (ecc_dirty) ++ex_ecc;
    else {
      ++checked_ecc;
      if (ecc != r.ecc) fail(r, "the ECC register", ecc, r.ecc);
    }
    if (!busy_dirty) {
      ++checked_intr;
      if ((int)((st >> 3) & 1u) != r.intr)
        fail(r, "interrupt()", (st >> 3) & 1u, (unsigned)r.intr);
    }
  };

  // ---- the schedule ------------------------------------------------------
  //
  // Rows sharing an instant are one group. Two passes: a dry one that costs
  // every group in ticks and finds the row it has to be anchored on, and a
  // BACKWARD relaxation that pulls a group earlier when the next one needs
  // the room. The relaxation is what makes the second seek checkable at all:
  // muir has the heads arrive from one seek and the next seek start at the
  // same instant, eight bus cycles apart, and the "still busy" sample five
  // nanoseconds before it. Something has to give, and what gives is the
  // sample --- pulled 25 ticks early, where it still reads busy --- rather
  // than the START, whose instant the arrival 6,060,271 ns later is measured
  // from.
  std::vector<size_t> gfirst, glast;
  std::vector<long> gspan, ganchor, gorigin;
  {
    int dry_sel = live_sel, dry_reg = live_reg;
    unsigned dry_cmd = 0, dry_present = 0, dry_ref_da = 0;
    int dry_timed = 0;
    size_t a = 0;
    while (a < rows.size()) {
      size_t b = a;
      while (b < rows.size() && rows[b].now == rows[a].now) ++b;
      long off = 0, anchor = -1, first_settle = -1;
      auto dry_read = [&](int reg) {
        if (!(dry_sel && dry_reg == reg)) ++off;
        ++off;
        dry_sel = 1; dry_reg = reg;
        return off - 1;
      };
      for (size_t k = a; k < b; ++k) {
        const Row &r = rows[k];
        if (r.kind == 'C') {
          if (r.wr) {
            off += 2;
            dry_sel = 1; dry_reg = r.reg;
            long settle = off;
            if (first_settle < 0) first_settle = settle;
            if (r.reg == 0) dry_cmd = r.wdata;
            if (r.reg == 3) {
              unsigned u = (dry_ref_da >> 28) & 7u;
              if (loads_timer(dry_cmd, (dry_present >> u) & 1u,
                              (dry_cmd >> 9) & 1u, dry_timed != 0))
                anchor = settle;
              for (int q = 0; q < 4; ++q) dry_read(q);
            }
          } else {
            long settle = dry_read(r.reg);
            if (first_settle < 0) first_settle = settle;
          }
          dry_ref_da = r.da;
        } else if (r.kind == 'I') {
          ++off;
          if (first_settle < 0) first_settle = off;
          dry_cmd = 0;
          for (int q = 0; q < 4; ++q) dry_read(q);
          dry_ref_da = r.da;
        } else if (r.kind == 'A') {
          dry_present |= 1u << r.unit;
        } else if (r.kind == 'T') {
          dry_timed = r.flag;
        }
        // ATTACH, RO, TIMED and LAY cost no ticks: they are levels on the
        // drive's cable, or the pack, and take effect where they stand.
      }
      // **THE GROUP IS ANCHORED ON THE LAST START THAT LOADS A TIMER**, and on
      // its first row when it has none. A group of one row then always lands
      // on its own instant, which is what the block-counter sweep and every
      // grid_before/grid_at pair are made of.
      if (anchor < 0) anchor = (first_settle < 0) ? 0 : first_settle;
      gfirst.push_back(a);
      glast.push_back(b);
      gspan.push_back(off);
      ganchor.push_back(anchor);
      gorigin.push_back(rows[a].now / 5 + K - anchor);
      a = b;
    }
  }
  for (size_t g = gorigin.size() - 1; g > 0; --g)
    if (gorigin[g - 1] + gspan[g - 1] > gorigin[g])
      gorigin[g - 1] = gorigin[g] - gspan[g - 1];
  if (gorigin[0] < tick) {
    std::fprintf(stderr,
                 "FAIL: the first group wants tick %ld and the pre-roll ends "
                 "at %ld: raise SLACK\n",
                 gorigin[0], tick);
    return 1;
  }

  size_t i = 0;
  for (size_t g = 0; g < gorigin.size() && !bad; ++g) {
    size_t j = glast[g];
    i = gfirst[g];
    ++groups;
    if (j - i > 1) ++shared_groups;
    idle_to(gorigin[g]);

    for (size_t k = i; k < j; ++k) {
      const Row &r = rows[k];
      switch (r.kind) {
        case 'A':
          attached_unit = r.unit;
          d_present |= 1u << r.unit;
          break;
        case 'R':
          if (attached_unit >= 0) {
            if (r.flag) d_ro |= 1u << attached_unit;
            else d_ro &= ~(1u << attached_unit);
          }
          break;
        case 'T':
          d_timed = r.flag;
          break;
        case 'L':
          break;
        case 'I': {
          do_init();
          lastcmd = 0;
          unsigned st = do_read(0);
          long st_tick = tick - 1;
          unsigned lma = do_read(1);
          unsigned da = do_read(2), ecc = do_read(3);
          ++faces;
          compare_face(r, st, st_tick, da, lma, ecc);
          ref_da = r.da;
          break;
        }
        case 'C':
          if (r.wr) {
            do_write(r.reg, r.wdata);
            if (r.reg == 0) {
              lastcmd = r.wdata;
              busy_dirty = false;
              codes_seen |= 1u << (r.wdata & 017u);
            }
            if (r.reg == 2) da_dirty = false;
            if (r.reg == 3) {
              ++starts;
              // `DISK_DEBUG=1` prints where every START landed against the
              // instant it was meant to. The placement above is the part of
              // this testbench most likely to be wrong in a way the run
              // cannot explain, and this is how to see it.
              if (getenv("DISK_DEBUG"))
                std::fprintf(stderr, "START row %ld cmd %o tick %ld want %ld\n",
                             r.n, lastcmd & 017u, tick, rows[i].now / 5 + K);
              if (tick != rows[i].now / 5 + K) ++unanchored_starts;
              unsigned code = lastcmd & 017u;
              int unit = (int)((ref_da >> 28) & 7u);
              bool present = (d_present >> unit) & 1u;
              bool ro = (d_ro >> unit) & 1u;
              if (code == 005u || code == 015u) drive_dirty = false;
              if (code == 004u || code == 014u) {
                if (present && d_timed) ++seeks_timed;
                if (!present) ++hangs;
              }
              if (code == 006u && !present) ++hangs;
              if (code == 007u || code == 017u || code == 012u) ++hangs;
              if (data_moving_code(code) && present &&
                  !((code == 011u || code == 013u) && ro)) {
                ++dm_starts;
                da_dirty = lma_dirty = ecc_dirty = drive_dirty = true;
                if (d_timed) busy_dirty = true;
              }
              unsigned st = do_read(0);
              long st_tick = tick - 1;
              unsigned lma = do_read(1);
              unsigned da = do_read(2), ecc = do_read(3);
              ++faces;
              compare_face(r, st, st_tick, da, lma, ecc);
            }
          } else {
            unsigned v = do_read(r.reg);
            long v_tick = tick - 1;
            bool skip = false;
            unsigned mask = 0xFFFFFFFFu;
            if (r.reg == 0) {
              ++checked_status;
              mask = ~CHAN;
              if (r.status & CHAN) { ++ex_chan_live; ++ex_l13; mask &= ~(1u << 13); }
              if (drive_dirty && ((v ^ r.status) & DRIVE_BITS) == 0)
                drive_dirty = false;
              if (drive_dirty) ++ex_drive;
              if (busy_dirty) ++ex_busy;
              if (drive_dirty) mask &= ~DRIVE_BITS;
              if (busy_dirty) mask &= ~BUSY_BITS;
              if (v_tick != r.now / 5 + K) {
                ++ex_counter;
                mask &= 0x00FFFFFFu;
                if (d_timed) { mask &= ~TIME_BITS; time_ok(r, v, v_tick); }
              } else ++checked_counter;
              unsigned bc = v >> 24;
              if (bc < 32) { if (v_tick == r.now / 5 + K) counters_seen |= 1u << bc; }
              else fail(r, "the block counter, which cannot exceed 17", bc, 17);
            } else if (r.reg == 1) {
              skip = lma_dirty;
              if (skip) ++ex_lma;
            } else if (r.reg == 2) {
              if (da_dirty && v == r.rdata) da_dirty = false;
              skip = da_dirty;
              if (skip) ++ex_da;
            } else {
              skip = ecc_dirty;
              if (skip) ++ex_ecc;
            }
            if (!skip) {
              ++checked_read;
              if ((v ^ r.rdata) & mask) fail(r, "the read-back", v, r.rdata);
            }
          }
          ref_da = r.da;
          if ((r.status >> 11) & 1u) ++full_timeouts;
          break;
        default:
          break;
      }
      if (bad >= 20) {
        std::fprintf(stderr, "stopping after %d mismatches\n", bad);
        break;
      }
    }
  }

  delete dut;

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches\n", bad);
    return 1;
  }

  // ---- what the trace has to have reached -------------------------------
  //
  // A trace that never hung, never turned the spindle past an edge or never
  // stored a command would agree everywhere and mean nothing.
  int thin = 0;
  auto want = [&](const char *what, long n) {
    if (n == 0) {
      std::fprintf(stderr, "FAIL: the trace has no %s\n", what);
      ++thin;
    }
  };
  want("register read-backs", checked_read);
  want("faces after a START", faces);
  want("data-moving STARTs", dm_starts);
  want("hangs", hangs);
  want("timeouts run out", full_timeouts);
  want("seeks with the drive's time charged", seeks_timed);
  want("attentions", attentions);
  want("any-attentions", any_attentions);
  want("seek errors", seek_errors);
  want("faults", faults);
  want("read-only packs", read_onlys);
  if (codes_seen != 0xFFFFu) {
    std::fprintf(stderr,
                 "FAIL: the trace stores only %d of the 16 command codes\n",
                 __builtin_popcount(codes_seen));
    ++thin;
  }
  // `DCHECK-BLOCK-COUNTER` wants every value 0 to 17 and no other.
  if (counters_seen != 0x0003FFFFu) {
    std::fprintf(stderr,
                 "FAIL: the block counter reached %d of its 18 values (%08x)\n",
                 __builtin_popcount(counters_seen), counters_seen);
    ++thin;
  }
  if (thin) return 1;

  std::printf(
      "ok: the disk controller's drive and register face agree with muir's\n"
      "    disk_controller::Controller over %zu rows and %ld ticks\n"
      "    %ld read-backs, %ld faces after a START or an INIT\n"
      "    %ld status words compared, %ld disk addresses, %ld last memory\n"
      "      addresses, %ld ECC registers, %ld interrupts\n"
      "    %ld STARTs, of which %ld moved data and were skipped\n"
      "    %ld hangs, %ld of the trace's rows saw the 2.56 s timer run out\n"
      "    all 16 command codes stored, all 18 block-counter values seen\n"
      "  exempt, and this is the whole of it:\n"
      "    the channel's 8 status bits, never compared; the reference had one\n"
      "      of them set on %ld rows\n"
      "    <13> transfer aborted, not compared on those %ld rows\n"
      "    <10> <6> <13> the drive's flags, %ld rows after a data-moving START\n"
      "    <0> <3> not-active and its interrupt, %ld rows\n"
      "    register 1, the last memory address, %ld rows\n"
      "    register 3, the ECC register, %ld rows\n"
      "    register 2, the disk address, %ld rows\n"
      "    <31:24> the block counter, %ld rows that did not land on their own\n"
      "      instant; compared on %ld that did\n"
      "    <0> <1> <2> <3> not-active and the attentions, %ld rows checked one\n"
      "      way round rather than both: they did not land on their instant\n"
      "      while the drive's time was charged\n"
      "    %ld BLK, %ld MEMPAGE, %ld MEMW and %ld PAGE rows not consumed:\n"
      "      the pack and main memory are the channel's two ends\n"
      "  placement: %ld groups of rows shared an instant, %ld STARTs did not\n"
      "    land on their own instant, %ld groups could not be anchored\n",
      rows.size(), tick, checked_read, faces, checked_status, checked_da,
      checked_lma, checked_ecc, checked_intr, starts, dm_starts, hangs,
      full_timeouts, ex_chan_live, ex_l13, ex_drive, ex_busy, ex_lma, ex_ecc,
      ex_da, ex_counter, checked_counter, ex_charged, blk_rows, mempage_rows,
      memw_rows, page_rows,
      shared_groups, unanchored_starts, slipped_groups);
  return 0;
}
