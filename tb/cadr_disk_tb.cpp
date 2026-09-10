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
// read back through four bus cycles of its own. And, since the channel
// landed, everything a transfer leaves behind it: every `PAGE` row word for
// word against a modelled main memory the controller reaches only through its
// own bus master, and every `BLK write` row against the block store, read back
// through the seam `S_AXI_HP2` will one day use.
//
// **THE MODEL MEMORY AND THE BLOCK STORE COME FROM THE STIMULUS AND NEVER
// FROM THE DUT.** CLAUDE.md's rule, twice over. Main memory here is filled
// from the trace's `MEMPAGE` and `MEMW` rows --- what the PROGRAM put there,
// never what the controller wrote --- and every destination page is filled
// before the read that is meant to overwrite it, with a word that is a
// function of both the page and the offset. So a transfer that never happened
// reads back as poison and not as the data, and a transfer that went to the
// wrong page reads back as some other page's poison. The block store is filled
// from `BLK load` and `BLK lay` rows, which are what a formatter and the pack's
// vendor put on the pack, and each of those words is a function of both the
// block and the offset for the same reason.
//
// **WHAT IS EXEMPT, AND IT IS BOUNDED AND COUNTED ON THE OUTPUT BELOW.** One
// thing, and it is the track: `0o02` Read All and `0o13` Write All go round
// the whole track as BYTES rather than as blocks, which wants the sector
// format serialised bit by bit and the parser that reads one back. The
// controller does their seek, their disk address and their `track_ns`, so
// their status word and register 2 are compared in full; what is not is
//
//   register 1, the last memory address
//       the walk writes it and this walk does not run. Exempt from a Read All
//       or Write All until the fabric and the reference are next observed to
//       agree, which the next ordinary transfer does.
//   the `PAGE` rows a Read All moved, and the `BLK write` rows a Write All
//   laid down
//       taken as STIMULUS instead: the pages are applied to the model memory
//       and the blocks loaded into the store, so that the ordinary Read which
//       follows finds on the pack exactly what muir's Write All left there ---
//       including the sector that claims to be block 9 of cylinder 3, which
//       is what makes the header compare checkable at all.
//
// Nothing else is exempt. The channel's eight status bits, the last memory
// address, the ECC register, the disk address after a walk and the drive's own
// flags are all compared on every row.
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
// **AND A WALK COSTS MORE TICKS THAN THE TRACE LEAVES BETWEEN TWO INSTANTS.**
// A block is 256 words on the bus and 1,028 shifts of the ECC register, and a
// checkword that fails is `Ecc::trap`'s 42,946 more; the 196-row group in the
// middle of the trace costs some hundreds of thousands of ticks where the
// trace gives two hundred. The fabric cannot go backwards, so it goes
// FORWARD A WHOLE TURN OF THE SPINDLE: `spin` counts five nanoseconds a tick
// and wraps at `REVOLUTION_NS`, so it repeats every 16,666,667 TICKS, and
// idling to the next tick congruent to the group's origin modulo that leaves
// the block counter exactly where muir has it and every countdown measuring
// the same interval it did. It is allowed only where the reference says the
// controller is not active and the drive's time is not charged --- otherwise
// eighty-three milliseconds would land inside something being timed --- and
// the run says how many times it was taken.
//
// HOW LONG A WALK TAKES IS THE FABRIC'S BUSINESS, so the rows after a START
// wait for the CHANNEL'S OWN REQUEST LINE to go quiet. That is a bus signal
// and not an answer: a master that has stopped asking has finished, and
// nothing about the controller's state is read to decide it. A walk that
// never stops asking hits the cap and the run says so rather than hanging.
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

// How long a walk may go on asking for words before the run calls it stuck.
// The largest one here is a block whose data checkword fails: 1,028 shifts to
// find that out, then `Ecc::trap`'s 42,946, then 256 bus cycles --- so this is
// four times the worst the trace can produce, and hitting it is a failure and
// not a timeout to be waited through.
const long WALK_CAP = 1 << 18;
// A few ticks after every START alike, so that the ones that start no walk
// still cost what the dry pass gave them.
const int WALK_QUIET = 4;

// The store's 260 places in a slot: 0..255 the block, then these.
const int ST_HEADER = 256, ST_HCK = 257, ST_DCK = 258, ST_TAG = 259;

// Whether a store into START loads a timer, which is the only thing whose
// instant has to be exact: a hang starts the 2.56 s counter, a seek or a
// recalibrate charges the drive's own time and arms its attention, and --- now
// that the channel is here --- a transfer charges its access time, which is
// the heads' move, the wait for the block to come round and a sector a block.
// All of them only when that time is charged at all.
bool loads_timer(unsigned code, bool present, bool recal, bool timed,
                 bool read_only) {
  switch (code & 017u) {
    case 007: case 017: case 012: return true;          // the sequencer hangs
    case 004: case 014: return !present || timed;       // hang, or the heads move
    case 006: return !present;                          // hang
    case 005: case 015: return present && timed && recal;  // the heads go home
    // A transfer, a Read All or a Write All: `access_ns` or `track_ns`. A
    // write to a read-only pack raises the fault and charges nothing.
    case 011: case 013: return present && timed && !read_only;
    case 000: case 001: case 002: case 003: case 010:
      return present && timed;
    default: return false;
  }
}

// The two commands whose data this slice does not move: the track, as bytes.
bool track_code(unsigned code) {
  return (code & 017u) == 002u || (code & 017u) == 013u;
}

// The four bits a running counter decides: not-active, its interrupt, and the
// two attentions. On a row the fabric reaches before or after muir's instant
// these are checked ONE WAY --- see the note at `time_ok` below.
const unsigned BUSY_BITS = (1u << 0) | (1u << 3);
// The eight the channel raises: `<22>` read-compare difference, `<21>` CCW
// cycle, `<20>` NXM, `<18>` header compare, `<17>` header ECC, `<16>` ECC
// hard, `<15>` ECC soft, `<14>` overrun.  `<19>` between them is memory
// parity, which `Controller` never sets and nothing here can raise.
const unsigned CHAN = (1u << 22) | (1u << 21) | (1u << 20) | (1u << 18) |
                      (1u << 17) | (1u << 16) | (1u << 15) | (1u << 14);
const unsigned TIME_BITS = BUSY_BITS | (1u << 2) | (1u << 1);

struct Row {
  char kind;        // 'C' CYC, 'I' INIT, 'A' ATTACH, 'R' RO, 'T' TIMED, 'L' LAY
                    // 'B' BLK, 'M' MEMPAGE, 'W' MEMW, 'P' PAGE
  long n;
  long now;
  int reg, wr;
  unsigned wdata, rdata;
  unsigned status, da, lma, ecc;
  int intr, pages;
  int unit, flag;
  // BLK: why (0 stimulus, 1 an expected output), slot, the address, the three
  // words.  MEMPAGE/PAGE: the page.  MEMW: the address and the word.
  int slot, cyl, head, blk, expected;
  unsigned page, addr, word;
  size_t words;     // where the 256 words live in `bulk`
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
  std::vector<unsigned> bulk;      // the 256-word bodies of BLK, MEMPAGE, PAGE
  long h_cyl = -1, h_heads = -1, h_bpt = -1;
  long h_timeout = -1, h_rev = -1, h_sector = -1, h_index = -1, h_pulse = -1;
  long h_ticks = -1;   // the trace's own last instant, in ticks
  long h_memory = -1, h_blockw = -1, h_slots = -1;
  long blk_rows = 0, mempage_rows = 0, memw_rows = 0, page_rows = 0;

  char line[8192];
  // BLK, MEMPAGE and PAGE rows are 256 words wide; read them with a big buffer.
  std::string big;
  long last_now = 0;
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
        else if (k == "memory_words") h_memory = a;
        else if (k == "block_words") h_blockw = a;
        else if (k == "slots") h_slots = a;
      }
      continue;
    }
    if (s[0] == '\n' || s[0] == '\0') continue;

    Row r;
    std::memset(&r, 0, sizeof r);
    // A row that carries no instant of its own belongs to the one before it:
    // `BLK`, `MEMPAGE`, `MEMW` and `PAGE` are the pack and main memory, which
    // the program touches between bus cycles and not at an instant.
    r.now = last_now;
    if (std::strncmp(s, "CYC ", 4) == 0) {
      r.kind = 'C';
      if (std::sscanf(s, "CYC %ld %ld %d %d %x %x %x %x %x %x %d %d",
                      &r.n, &r.now, &r.reg, &r.wr, &r.wdata, &r.rdata,
                      &r.status, &r.da, &r.lma, &r.ecc, &r.intr,
                      &r.pages) != 12) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, s);
        return 2;
      }
      last_now = r.now;
      rows.push_back(r);
    } else if (std::strncmp(s, "INIT ", 5) == 0) {
      r.kind = 'I';
      if (std::sscanf(s, "INIT %ld %ld %x %x %x %x %d", &r.n, &r.now,
                      &r.status, &r.da, &r.lma, &r.ecc, &r.intr) != 7) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, s);
        return 2;
      }
      last_now = r.now;
      rows.push_back(r);
    } else if (std::strncmp(s, "ATTACH ", 7) == 0) {
      r.kind = 'A';
      long slots;
      if (std::sscanf(s, "ATTACH %ld %ld %d %ld", &r.n, &r.now, &r.unit,
                      &slots) != 4) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, s);
        return 2;
      }
      last_now = r.now;
      rows.push_back(r);
    } else if (std::strncmp(s, "RO ", 3) == 0) {
      r.kind = 'R';
      if (std::sscanf(s, "RO %ld %ld %d", &r.n, &r.now, &r.flag) != 3) return 2;
      last_now = r.now;
      rows.push_back(r);
    } else if (std::strncmp(s, "TIMED ", 6) == 0) {
      r.kind = 'T';
      if (std::sscanf(s, "TIMED %ld %ld %d", &r.n, &r.now, &r.flag) != 3)
        return 2;
      last_now = r.now;
      rows.push_back(r);
    } else if (std::strncmp(s, "LAY ", 4) == 0) {
      r.kind = 'L';
      if (std::sscanf(s, "LAY %ld %ld", &r.n, &r.now) != 2) return 2;
      last_now = r.now;
      rows.push_back(r);
    } else if (std::strncmp(s, "BLK ", 4) == 0) {
      // `BLK why slot lba cyl head blk header hck dck w0..w255`.  `why` is the
      // whole of the difference between stimulus and an expected output, and
      // the generator's own comment says the first model written against this
      // trace got it wrong for want of it.
      r.kind = 'B';
      char why[16];
      unsigned lba;
      if (std::sscanf(s, "BLK %15s %d %x %x %x %x %x %x %x", why, &r.slot,
                      &lba, (unsigned *)&r.cyl, (unsigned *)&r.head,
                      (unsigned *)&r.blk, &r.page, &r.addr, &r.word) != 9) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, s);
        return 2;
      }
      r.expected = (std::strcmp(why, "write") == 0);
      // The 256 words after the nine fields.
      const char *p = s;
      for (int k = 0; k < 10; ++k) {
        p = std::strchr(p, ' ');
        if (!p) { std::fprintf(stderr, "%s: short BLK row\n", path); return 2; }
        ++p;
      }
      r.words = bulk.size();
      for (int i = 0; i < 256; ++i) {
        unsigned w = 0;
        if (std::sscanf(p, "%x", &w) != 1) {
          std::fprintf(stderr, "%s: short BLK row at word %d\n", path, i);
          return 2;
        }
        bulk.push_back(w);
        p = std::strchr(p, ' ');
        if (!p && i != 255) { std::fprintf(stderr, "%s: short BLK row\n", path); return 2; }
        if (p) ++p;
      }
      ++blk_rows;
      rows.push_back(r);
    } else if (std::strncmp(s, "MEMPAGE ", 8) == 0 ||
               std::strncmp(s, "PAGE ", 5) == 0) {
      const bool mem = s[0] == 'M';
      r.kind = mem ? 'M' : 'P';
      const char *p = std::strchr(s, ' ');
      if (!p || std::sscanf(p + 1, "%x", &r.page) != 1) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, s);
        return 2;
      }
      p = std::strchr(p + 1, ' ');
      if (!p) { std::fprintf(stderr, "%s: short page row\n", path); return 2; }
      ++p;
      r.words = bulk.size();
      for (int i = 0; i < 256; ++i) {
        unsigned w = 0;
        if (std::sscanf(p, "%x", &w) != 1) {
          std::fprintf(stderr, "%s: short page row at word %d\n", path, i);
          return 2;
        }
        bulk.push_back(w);
        p = std::strchr(p, ' ');
        if (!p && i != 255) { std::fprintf(stderr, "%s: short page row\n", path); return 2; }
        if (p) ++p;
      }
      if (mem) ++mempage_rows; else ++page_rows;
      rows.push_back(r);
    } else if (std::strncmp(s, "MEMW ", 5) == 0) {
      r.kind = 'W';
      if (std::sscanf(s, "MEMW %x %x", &r.addr, &r.word) != 2) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, s);
        return 2;
      }
      ++memw_rows;
      rows.push_back(r);
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
      {"BLOCK_WORDS", h_blockw, 256},
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
  // The store has to be big enough for every block the program watches at
  // once.  A trace that grew past the parameter would otherwise show up as a
  // missing block in the middle of a walk.
  const long SLOTS = 24;
  if (h_slots < 0 || h_slots > SLOTS) {
    std::fprintf(stderr,
                 "FAIL: the trace watches %ld blocks and the block store has "
                 "%ld slots\n",
                 h_slots, SLOTS);
    ++wrong;
  }
  if (h_memory <= 0) {
    std::fprintf(stderr, "FAIL: %s has no memory_words in its header\n", path);
    ++wrong;
  }
  if (wrong) return 1;

  if (h_ticks < 0) {
    std::fprintf(stderr, "FAIL: %s has no tick count in its header\n", path);
    return 1;
  }

  auto *dut = new Vcadr_disk_controller;

  // ---- main memory, as the PROGRAM fills it ------------------------------
  //
  // Word-addressed, and a word nothing wrote reads zero, which is what
  // `Controller`'s own `main` does.  The controller reaches it only through
  // its bus master, and nothing the controller writes is ever used to decide
  // what it should have written.
  std::vector<unsigned> mem((size_t)h_memory, 0u);

  // ---- the driver --------------------------------------------------------
  long tick = 0;
  int d_sel = 0, d_rq = 0, d_wr = 0, d_init = 0, d_rst = 1;
  unsigned d_phys = 0, d_wdata = 0;
  unsigned d_present = 0, d_ro = 0;
  int d_timed = 0;
  // What `mine` and `which` will hold during the NEXT tick: the address match
  // is held in a register, so a read has to be set up a tick ahead.
  int live_sel = 0, live_reg = -1;

  // The channel's answer.  A latency that varies, because a fixed one lets a
  // master that assumed one pass; small, because a block is 256 of them.
  long ch_up = -1;
  int ch_served = 0;
  long ch_serial = 0;
  long ch_reads = 0, ch_writes = 0, ch_nxms = 0;
  int miss_seen = 0;

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

    // The channel, answered after the request has stood a tick or three.
    dut->ch_done = 0;
    dut->ch_nxm = 0;
    if (!dut->ch_req) {
      ch_up = -1;
      ch_served = 0;
    } else {
      if (ch_up < 0) ch_up = tick;
      const long lat = 1 + (ch_serial % 3);
      if (!ch_served && tick - ch_up >= lat) {
        ch_served = 1;
        ++ch_serial;
        const unsigned a = dut->ch_addr;
        if (a >= (unsigned)h_memory) {
          dut->ch_nxm = 1;
          ++ch_nxms;
        } else if (dut->ch_write) {
          mem[a] = dut->ch_wdata;
          ++ch_writes;
        } else {
          dut->ch_rdata = mem[a];
          ++ch_reads;
        }
        dut->ch_done = 1;
      }
    }
    if (dut->store_miss) ++miss_seen;

    dut->eval();
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

  // The block store's seam, one word a tick each way.  `store_rdata` is a
  // tick behind, as a block RAM's read is, so a read costs exactly one tick
  // and the word is there when it ends.
  auto store_write = [&](int slot, int addr, unsigned v) {
    dut->store_we = 1;
    dut->store_slot = slot;
    dut->store_addr = addr;
    dut->store_wdata = v;
    run_tick(false);
    dut->store_we = 0;
  };
  auto store_read = [&](int slot, int addr) -> unsigned {
    dut->store_we = 0;
    dut->store_slot = slot;
    dut->store_addr = addr;
    run_tick(false);
    return dut->store_rdata;
  };
  dut->store_we = 0;
  dut->store_slot = 0;
  dut->store_addr = 0;
  dut->store_wdata = 0;

  // **A TURN OF THE SPINDLE ONCE TAKEN IS TAKEN FOR EVER.**  The fabric is
  // then that many ticks ahead of muir's clock for the rest of the run, and
  // every later group has to be placed the same amount later or the INTERVAL
  // between two of them --- which is what every countdown in the module
  // measures --- would come out short by a turn.  So it is an offset and not
  // a per-group decision, and only a NEW turn asks the question below.
  long turns = 0;
  long realignments = 0;
  long walk_ticks = 0;

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

  int stuck = 0;
  // The walk, waited out on the channel's own interlock.  `ch_active` is what
  // `S_AXI_HP2` will have to look at before it touches a slot, so waiting on
  // it here is the seam being used and not a peek inside: a controller that
  // dropped it early would be read in the middle of a walk and disagree with
  // every column, and one that never dropped it hits the cap below.
  auto settle_walk = [&]() {
    d_rq = 0;
    const long began = tick;
    while (dut->ch_active) {
      run_tick(false);
      if (tick - began > WALK_CAP) {
        std::fprintf(stderr,
                     "FAIL: the channel was still walking %ld ticks after a "
                     "START\n",
                     tick - began);
        ++stuck;
        break;
      }
    }
    // And a few ticks more, which the dry pass costs every START alike so
    // that a START starting no walk still lands where it was placed.
    for (int q = 0; q < WALK_QUIET; ++q) run_tick(false);
    walk_ticks += tick - began;
    if (getenv("DISK_DEBUG"))
      std::fprintf(stderr, "walk %ld ticks, miss=%d reads=%ld writes=%ld nxm=%ld\n",
                   tick - began, (int)dut->store_miss, ch_reads, ch_writes, ch_nxms);
  };

  // ---- what the run counts ----------------------------------------------
  long checked_read = 0, checked_status = 0, checked_da = 0, checked_lma = 0;
  long checked_ecc = 0, checked_intr = 0, faces = 0;
  long ex_lma = 0, ex_counter = 0, checked_counter = 0;
  long ex_charged = 0;
  long dm_starts = 0, track_starts = 0, starts = 0, unanchored_starts = 0;
  long groups = 0, shared_groups = 0;
  long full_timeouts = 0, hangs = 0;
  long blk_loaded = 0, blk_compared = 0, blk_stimulus = 0;
  long pages_compared = 0, pages_stimulus = 0, page_words = 0;
  unsigned counters_seen = 0;   // a bit a block-counter value
  unsigned codes_seen = 0;      // a bit a command code
  unsigned chan_bits_seen = 0;  // a bit a channel status bit ever compared
  long seeks_timed = 0, attentions = 0, any_attentions = 0;
  long seek_errors = 0, faults = 0, read_onlys = 0;
  int bad = 0;

  bool lma_dirty = false, track_stimulus = false;
  // **A COUNTDOWN THAT MAY STILL BE RUNNING**, which is what decides whether a
  // row off its own instant may be checked both ways.  It used to be
  // `drive_timed` at the moment of the row, and that was a proxy that stopped
  // being true when the channel landed: the trace turns the drive's time OFF
  // in the middle of a group whose seek, charged while it was on, has not
  // finished --- so the flag says instead that something was loaded and the
  // two have not been seen to agree about it since.  Same idiom as the disk
  // address's, and it recovers at the first row where the reference says the
  // controller is not active AND the two agree --- agreeing that both are
  // BUSY is not enough, because that is what a counter still running looks
  // like on both sides.
  bool timed_dirty = false;
  unsigned lastcmd = 0;
  unsigned ref_da = 0;   // the reference's disk address as of the last row
  unsigned last_ref_status = 1;
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
  // real check on the rows where a counter is still running and the placement
  // is not exact, where masking the four bits would be none.
  auto time_ok = [&](const Row &r, unsigned st, long st_tick) {
    ++ex_charged;
    bool early = st_tick < r.now / 5 + K + turns;
    unsigned wrong2 = early ? (st & TIME_BITS & ~r.status)
                            : (r.status & TIME_BITS & ~st);
    if (wrong2)
      fail(r, early ? "not-active or an attention, ahead of muir's instant"
                    : "not-active or an attention, behind muir's instant",
           st & TIME_BITS, r.status & TIME_BITS);
  };

  // The comparison of one whole face against one row.
  auto compare_face = [&](const Row &r, unsigned st, long st_tick, unsigned da,
                          unsigned lma, unsigned ecc) {
    unsigned mask = 0xFFFFFFFFu;
    // **THE BLOCK COUNTER IS COMPARED ONLY WHERE THE ROW LANDS ON ITS OWN
    // INSTANT.**  The spindle turns while the fabric works through a group of
    // rows the model puts at one instant, and 196 of them is about 3.5 us
    // against regions of 968 --- enough to cross an edge, and instant
    // 2,583,337,385 is 4,000 ns into a revolution, which is the index pulse's
    // trailing edge exactly.  Every row of the block-counter sweep has an
    // instant to itself and is compared; a row that shares one is not.
    if (st_tick != r.now / 5 + K + turns) {
      ++ex_counter;
      mask &= 0x00FFFFFFu;
      if (timed_dirty) { mask &= ~TIME_BITS; time_ok(r, st, st_tick); }
    } else ++checked_counter;
    if (timed_dirty && (r.status & 1u) &&
        (st & TIME_BITS) == (r.status & TIME_BITS))
      timed_dirty = false;
    ++checked_status;
    if ((st ^ r.status) & mask) fail(r, "the status word", st, r.status);
    chan_bits_seen |= r.status & CHAN;
    unsigned bc = st >> 24;
    if (bc < 32) { if (st_tick == r.now / 5 + K + turns) counters_seen |= 1u << bc; }
    else fail(r, "the block counter, which cannot exceed 17", bc, 17);
    if ((st >> 10) & 1) ++seek_errors;
    if ((st >> 7) & 1) ++read_onlys;
    if ((st >> 6) & 1) ++faults;
    if ((st >> 2) & 1) ++attentions;
    if ((st >> 1) & 1) ++any_attentions;

    ++checked_da;
    if (da != r.da) fail(r, "the disk address", da, r.da);

    if (lma_dirty && lma == r.lma) lma_dirty = false;
    if (lma_dirty) ++ex_lma;
    else {
      ++checked_lma;
      if (lma != r.lma) fail(r, "the last memory address", lma, r.lma);
    }
    ++checked_ecc;
    if (ecc != r.ecc) fail(r, "the ECC register", ecc, r.ecc);
    ++checked_intr;
    if ((int)((st >> 3) & 1u) != r.intr)
      fail(r, "interrupt()", (st >> 3) & 1u, (unsigned)r.intr);
    last_ref_status = r.status;
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
  //
  // What the dry pass does NOT cost is a walk: how long the channel takes is
  // the fabric's business, it happens after the START it belongs to, and the
  // group after it is placed by the turn-of-the-spindle rule instead.
  std::vector<size_t> gfirst, glast;
  std::vector<long> gspan, ganchor, gorigin;
  {
    int dry_sel = live_sel, dry_reg = live_reg;
    unsigned dry_cmd = 0, dry_present = 0, dry_ro = 0, dry_ref_da = 0;
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
                              (dry_cmd >> 9) & 1u, dry_timed != 0,
                              ((dry_ro >> u) & 1u) != 0))
                anchor = settle;
              off += WALK_QUIET;
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
        } else if (r.kind == 'R') {
          if (r.flag) dry_ro |= 1u << (unsigned)(attached_unit < 0 ? 0 : 0);
          else dry_ro = 0;
        } else if (r.kind == 'T') {
          dry_timed = r.flag;
        } else if (r.kind == 'B') {
          // Filling a slot is 260 words at a word a tick, and reading one back
          // to compare is 259.
          off += r.expected ? 259 : 260;
        }
        // ATTACH, RO, TIMED, LAY, MEMPAGE, MEMW and PAGE cost no ticks: they
        // are levels on the drive's cable, or memory the program filled.
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
  for (size_t g = 0; g < gorigin.size() && !bad && !stuck; ++g) {
    size_t j = glast[g];
    i = gfirst[g];
    ++groups;
    if (j - i > 1) ++shared_groups;
    // **A GROUP THE FABRIC CANNOT REACH IN TIME GOES FORWARD A WHOLE TURN.**
    // See the note at the top: `spin` repeats every 16,666,667 ticks, so this
    // leaves the block counter and every interval exactly where muir has
    // them.  It is only sound where nothing is being timed.
    long origin = gorigin[g] + turns;
    while (origin < tick) {
      if (d_timed || !(last_ref_status & 1u)) {
        std::fprintf(stderr,
                     "FAIL: the fabric is %ld ticks past the instant of row "
                     "%ld and cannot go forward a turn of the spindle: the "
                     "drive's time is %scharged and the reference's status is "
                     "%08x\n",
                     tick - origin, rows[i].n, d_timed ? "" : "not ",
                     last_ref_status);
        ++stuck;
        break;
      }
      origin += REVOLUTION_NS;
      turns  += REVOLUTION_NS;
      ++realignments;
    }
    if (stuck) break;
    idle_to(origin);

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
        // Main memory as the program filled it.
        case 'M':
          for (int w = 0; w < 256; ++w)
            mem[(size_t)r.page * 256u + w] = bulk[r.words + w];
          break;
        case 'W':
          mem[r.addr] = r.word;
          break;
        // A page the transfer put into main memory.
        case 'P':
          if (track_stimulus) {
            ++pages_stimulus;
            for (int w = 0; w < 256; ++w)
              mem[(size_t)r.page + w] = bulk[r.words + w];
          } else {
            ++pages_compared;
            for (int w = 0; w < 256; ++w) {
              ++page_words;
              if (mem[(size_t)r.page + w] != bulk[r.words + w]) {
                fail(r, "a word of a page the transfer moved",
                     mem[(size_t)r.page + w], bulk[r.words + w]);
                std::fprintf(stderr, "  page %x word %d\n", r.page, w);
                break;
              }
            }
          }
          break;
        // The pack.  A `load` or `lay` row is what a formatter put there and
        // is written into the store; a `write` row is what a transfer left
        // and the store must already hold it.
        case 'B': {
          const unsigned tag = ((unsigned)r.cyl << 16) |
                               ((unsigned)r.head << 8) | (unsigned)r.blk;
          if (r.expected && !track_stimulus) {
            ++blk_compared;
            unsigned got = store_read(r.slot, ST_HEADER);
            if (got != r.page) fail(r, "the block's header", got, r.page);
            got = store_read(r.slot, ST_HCK);
            if (got != r.addr) fail(r, "the block's header checkword", got, r.addr);
            got = store_read(r.slot, ST_DCK);
            if (got != r.word) fail(r, "the block's data checkword", got, r.word);
            for (int w = 0; w < 256 && !bad; ++w) {
              got = store_read(r.slot, w);
              if (got != bulk[r.words + w]) {
                fail(r, "a word of the block the transfer wrote", got,
                     bulk[r.words + w]);
                std::fprintf(stderr, "  slot %d word %d\n", r.slot, w);
              }
            }
          } else {
            if (r.expected) ++blk_stimulus; else ++blk_loaded;
            for (int w = 0; w < 256; ++w)
              store_write(r.slot, w, bulk[r.words + w]);
            store_write(r.slot, ST_HEADER, r.page);
            store_write(r.slot, ST_HCK, r.addr);
            store_write(r.slot, ST_DCK, r.word);
            store_write(r.slot, ST_TAG, tag);
          }
          break;
        }
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
              codes_seen |= 1u << (r.wdata & 017u);
            }
            if (r.reg == 3) {
              ++starts;
              // `DISK_DEBUG=1` prints where every START landed against the
              // instant it was meant to. The placement above is the part of
              // this testbench most likely to be wrong in a way the run
              // cannot explain, and this is how to see it.
              if (getenv("DISK_DEBUG"))
                std::fprintf(stderr, "START row %ld cmd %o tick %ld want %ld\n",
                             r.n, lastcmd & 017u, tick, rows[i].now / 5 + K + turns);
              if (tick != rows[i].now / 5 + K + turns) ++unanchored_starts;
              unsigned code = lastcmd & 017u;
              int unit = (int)((ref_da >> 28) & 7u);
              bool present = (d_present >> unit) & 1u;
              bool ro = (d_ro >> unit) & 1u;
              if (code == 004u || code == 014u) {
                if (present && d_timed) ++seeks_timed;
                if (!present) ++hangs;
              }
              if (code == 006u && !present) ++hangs;
              if (code == 007u || code == 017u || code == 012u) ++hangs;
              if (loads_timer(lastcmd, present, (lastcmd >> 9) & 1u,
                              d_timed != 0, ro))
                timed_dirty = true;
              track_stimulus = false;
              if (present && !((code == 011u || code == 013u) && ro)) {
                if (track_code(code)) {
                  ++track_starts;
                  track_stimulus = true;
                  lma_dirty = true;
                } else if (code == 000u || code == 010u || code == 011u) {
                  ++dm_starts;
                }
              }
              settle_walk();
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
              chan_bits_seen |= r.status & CHAN;
              if (v_tick != r.now / 5 + K + turns) {
                ++ex_counter;
                mask &= 0x00FFFFFFu;
                if (timed_dirty) { mask &= ~TIME_BITS; time_ok(r, v, v_tick); }
              } else ++checked_counter;
              if (timed_dirty && (r.status & 1u) &&
                  (v & TIME_BITS) == (r.status & TIME_BITS))
                timed_dirty = false;
              unsigned bc = v >> 24;
              if (bc < 32) { if (v_tick == r.now / 5 + K + turns) counters_seen |= 1u << bc; }
              else fail(r, "the block counter, which cannot exceed 17", bc, 17);
            } else if (r.reg == 1) {
              if (lma_dirty && v == r.rdata) lma_dirty = false;
              skip = lma_dirty;
              if (skip) ++ex_lma;
            }
            if (!skip) {
              ++checked_read;
              if ((v ^ r.rdata) & mask) fail(r, "the read-back", v, r.rdata);
            }
            last_ref_status = r.status;
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

  if (stuck) return 1;
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches\n", bad);
    return 1;
  }
  if (miss_seen) {
    std::fprintf(stderr,
                 "FAIL: the walk asked the block store for a block it does not "
                 "hold, on %d ticks\n",
                 miss_seen);
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
  want("transfers that walked a command list", dm_starts);
  want("hangs", hangs);
  want("timeouts run out", full_timeouts);
  want("seeks with the drive's time charged", seeks_timed);
  want("attentions", attentions);
  want("any-attentions", any_attentions);
  want("seek errors", seek_errors);
  want("faults", faults);
  want("read-only packs", read_onlys);
  want("blocks loaded into the store", blk_loaded);
  want("blocks a transfer wrote and the store was compared on", blk_compared);
  want("pages compared word for word", pages_compared);
  want("words the channel read out of main memory", ch_reads);
  want("words the channel wrote into main memory", ch_writes);
  want("channel cycles main memory did not answer", ch_nxms);
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
  // The eight the channel raises. `<21>` CCW cycle is set and cleared inside
  // one fetch, so no read can see it and the reference never carries it; the
  // other seven have to have been met, or "compared" would mean nothing.
  if ((chan_bits_seen | (1u << 21)) != CHAN) {
    std::fprintf(stderr,
                 "FAIL: the reference raises only %d of the channel's 8 status "
                 "bits (%08x)\n",
                 __builtin_popcount(chan_bits_seen), chan_bits_seen);
    ++thin;
  }
  if (thin) return 1;

  std::printf(
      "ok: the disk controller agrees with muir's disk_controller::Controller\n"
      "    over %zu rows and %ld ticks\n"
      "    %ld read-backs, %ld faces after a START or an INIT\n"
      "    %ld status words compared, %ld disk addresses, %ld last memory\n"
      "      addresses, %ld ECC registers, %ld interrupts\n"
      "    %ld STARTs, of which %ld walked a command list and %ld went round\n"
      "      a track\n"
      "    %ld hangs, %ld of the trace's rows saw the 2.56 s timer run out\n"
      "    all 16 command codes stored, all 18 block-counter values seen,\n"
      "      7 of the channel's 8 status bits raised (%08x; <21> is set and\n"
      "      cleared inside one fetch and no read can see it)\n"
      "  the channel, held to the property and not to a trace:\n"
      "    %ld words read out of main memory, %ld written into it, %ld cycles\n"
      "      main memory did not answer\n"
      "    %ld pages compared word for word (%ld words), %ld blocks loaded\n"
      "      into the store, %ld blocks a transfer wrote compared against it\n"
      "    %ld ticks spent walking\n"
      "  exempt, and this is the whole of it:\n"
      "    register 1, the last memory address, %ld rows after a Read All or\n"
      "      a Write All, until it and the reference next agree\n"
      "    %ld pages and %ld blocks a Read All or a Write All moved, taken as\n"
      "      stimulus: the track is bytes and not blocks, and is not built\n"
      "    <31:24> the block counter, %ld rows that did not land on their own\n"
      "      instant; compared on %ld that did\n"
      "    <0> <1> <2> <3> not-active and the attentions, %ld rows checked one\n"
      "      way round rather than both: they did not land on their instant\n"
      "      while a counter a START had loaded was still running\n"
      "  placement: %ld groups of rows shared an instant, %ld STARTs did not\n"
      "    land on their own instant, %ld turns of the spindle idled through\n"
      "    to let a walk finish\n",
      rows.size(), tick, checked_read, faces, checked_status, checked_da,
      checked_lma, checked_ecc, checked_intr, starts, dm_starts, track_starts,
      hangs, full_timeouts, chan_bits_seen,
      ch_reads, ch_writes, ch_nxms,
      pages_compared, page_words, blk_loaded, blk_compared, walk_ticks,
      ex_lma, pages_stimulus, blk_stimulus,
      ex_counter, checked_counter, ex_charged,
      shared_groups, unanchored_starts, realignments);
  return 0;
}
