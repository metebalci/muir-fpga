// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Drives the disk controller with its pack side underneath ---
// `tb/cadr_disk_harness.sv`, which is `rtl/cadr_disk_controller.sv` and
// `rtl/cadr_disk_pack.sv` wired as the board wires them --- from the
// reference trace and compares the register face. The trace is written by
// golden/src/disk.rs out of muir's own disk_controller::Controller, driven
// register by register, and carries the stimulus --- the drive, its read-only
// switch, whether its time is charged, and the pack --- as well as the
// expected outputs.
//
// WHAT THIS CHECK HOLDS TO. Every `CYC` read row's read-back, and after every
// `START` and every `INIT` the whole observable face: the status word, the
// disk address, the last memory address, the ECC register and `interrupt()`,
// read back through four bus cycles of its own. And, since the channel
// landed, everything a transfer leaves behind it: every `PAGE` row word for
// word against a modelled main memory the controller reaches only through its
// own bus master, and every `BLK write` row against the block store --- which
// is now READ BACK THE WAY THE BOARD WILL READ IT: the pack side writes the
// slot back over `S_AXI_HP2` to the address the row names, into a modelled
// DDR this testbench seeded with poison, and the record there is compared.
//
// **THE MODEL MEMORY, THE DDR AND THE BLOCK STORE COME FROM THE STIMULUS AND
// NEVER FROM THE DUT.** CLAUDE.md's rule, three times over. Main memory here
// is filled from the trace's `MEMPAGE` and `MEMW` rows --- what the PROGRAM
// put there, never what the controller wrote --- and every destination page
// is filled before the read that is meant to overwrite it, with a word that
// is a function of both the page and the offset. So a transfer that never
// happened reads back as poison and not as the data, and a transfer that went
// to the wrong page reads back as some other page's poison. The block store
// is filled from `BLK load` and `BLK lay` rows, which are what a formatter
// and the pack's vendor put on the pack: each row's 259 words are put in the
// modelled DDR at the address the ROW names --- the generator's choice,
// spread across the address bits --- and the fabric is told that address over
// `M_AXI_GP0` and fetches them itself. Nothing here writes the store.
//
// **THE PACK SIDE'S EVERY MOVE COSTS THE SAME TICKS, AND THE COST IS
// MEASURED, NOT ASSUMED.** A fetch is nine AXI bursts and some hundreds of
// ticks and it sits inside a group of rows the trace puts at one instant, so
// the schedule below has to know exactly what it costs or the rows after it
// land off their instant. So the slave answers with FIXED delays here ---
// the varying ones are `tb/cadr_disk_pack_tb.cpp`'s business --- and the
// pre-roll runs one fetch, one write-back and one register write into a
// scratch slot the trace does not use and takes their lengths as the budget.
// Every move is then padded to its budget, and one that runs over fails the
// run.
//
// **NOTHING A COMMAND DOES IS EXEMPT ANY MORE.** `0o02` Read All and `0o13`
// Write All go round the whole track as BYTES rather than as blocks, and the
// serialiser and the parser that do that are in the module now: the three
// `PAGE` rows a Read All moved and the two `BLK write` rows a Write All laid
// down are COMPARED, where they were taken as stimulus, and so is register 1
// after one. The channel's eight status bits, the last memory address, the
// ECC register, the disk address after a walk and the drive's own flags are
// all compared on every row. What is left is the two things that cannot move
// --- the block counter on a row that did not land on its own instant, and a
// row checked one way round because a counter was still running --- and both
// are counted on the output below.
//
// **AND THE TWO HALVES ARE HELD TO EACH OTHER AS WELL AS TO muir**, which
// the trace alone cannot do: it reads three pages of a track and lays two
// sectors of one, and the track is seventeen. So after the last row the run
// goes on and does what the trace cannot afford --- Read All of a whole
// track into twenty pages, checked byte for byte against `disk_unit::format`
// written out here from the store's own words, and then Write All of exactly
// those pages back, which must leave all seventeen blocks as they were. A
// serialiser and a parser that were wrong in inverse ways would survive the
// round trip; the trace's five rows are what stops that, and the round trip
// is what reaches the fourteen sectors and the 17,088 bytes the trace never
// looks at.
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
// timer, so it is the only row whose instant has to be exact.  The instant of
// a store is the tick its request is first up; the controller takes the store
// two ticks later and loads its timers two ticks short to say so, and a write
// here costs four ticks so that the read after it sees the registers. The hang in
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
// wait for the CHANNEL'S OWN INTERLOCK to go quiet. That is a bus signal
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
#include <set>
#include <string>
#include <vector>

#include "Vcadr_disk_harness.h"
#include "cadr_pack_side.h"
#include "verilated.h"

using namespace pack_side;

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
// The longest is no longer a block but a TRACK: the property check after the
// trace writes a whole one, 5,120 words off the bus and thirty-two bits of
// each through the parser a bit at a time, about 184,000 ticks. (The trace's
// own worst is a block whose data checkword fails --- 1,028 shifts to find
// that out, then `Ecc::trap`'s 42,946, then 256 bus cycles.) This is five
// times the worst either can produce, and hitting it is a failure and not a
// timeout to be waited through.
const long WALK_CAP = 1 << 20;
// A few ticks after every START alike, so that the ones that start no walk
// still cost what the dry pass gave them.
const int WALK_QUIET = 4;

// The record's three words after the block, as the row and the DDR have them.
const int ST_HEADER = 256, ST_HCK = 257, ST_DCK = 258;

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
                    // 'B' BLK, 'M' MEMPAGE, 'W' MEMW, 'P' PAGE, 'N' NEED
  long n;
  long now;
  int reg, wr;
  unsigned wdata, rdata;
  unsigned status, da, lma, ecc;
  int intr, pages;
  int unit, flag;
  // BLK: why (0 stimulus, 1 an expected output), slot, the block's address
  // in DDR, the disk address, the three words.  MEMPAGE/PAGE: the page.
  // MEMW: the address and the word.  NEED: the disk address and its lba.
  int slot, cyl, head, blk, expected;
  unsigned page, addr, word, lba;
  unsigned long long at;
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
  long h_record = -1, h_align = -1, h_needed = -1;
  long blk_rows = 0, mempage_rows = 0, memw_rows = 0, page_rows = 0;
  long need_rows = 0;

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
        else if (k == "record_bytes") h_record = a;
        else if (k == "record_align") h_align = a;
        else if (k == "blocks_needed") h_needed = a;
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
      // `BLK why slot at lba cyl head blk header hck dck w0..w255`.  `why`
      // is the whole of the difference between stimulus and an expected
      // output, and the generator's own comment says the first model written
      // against this trace got it wrong for want of it.  `at` is the block's
      // address in DDR: where the record is put for the fabric to fetch, or
      // where the fabric is sent to write it back.
      r.kind = 'B';
      char why[16];
      if (std::sscanf(s, "BLK %15s %d %llx %x %x %x %x %x %x %x", why, &r.slot,
                      &r.at, &r.lba, (unsigned *)&r.cyl, (unsigned *)&r.head,
                      (unsigned *)&r.blk, &r.page, &r.addr, &r.word) != 10) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, s);
        return 2;
      }
      r.expected = (std::strcmp(why, "write") == 0);
      // The 256 words after the ten fields.
      const char *p = s;
      for (int k = 0; k < 11; ++k) {
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
    } else if (std::strncmp(s, "NEED ", 5) == 0) {
      // A block the START before it read off the pack.
      r.kind = 'N';
      if (std::sscanf(s, "NEED %x %x %x %x", &r.lba, (unsigned *)&r.cyl,
                      (unsigned *)&r.head, (unsigned *)&r.blk) != 4) {
        std::fprintf(stderr, "%s: cannot parse: %s", path, s);
        return 2;
      }
      ++need_rows;
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
  // once, AND ONE MORE: the slot the pre-roll measures a fetch and a
  // write-back in, which no row may use.  A trace that grew past the
  // parameter would otherwise show up as a missing block in the middle of a
  // walk.
  const long SLOTS = 24;
  const int SCRATCH = SLOTS - 1;
  if (h_slots < 0 || h_slots >= SLOTS) {
    std::fprintf(stderr,
                 "FAIL: the trace watches %ld blocks and the block store has "
                 "%ld slots, one of which this testbench needs for itself\n",
                 h_slots, SLOTS);
    ++wrong;
  }
  if (h_record != RECORD_WORDS * 4 || h_align != (long)RECORD_ALIGN) {
    std::fprintf(stderr,
                 "FAIL: the trace's record is %ld bytes aligned to %ld and "
                 "the pack side's is %d aligned to %u\n",
                 h_record, h_align, RECORD_WORDS * 4, RECORD_ALIGN);
    ++wrong;
  }
  if (h_needed != need_rows) {
    std::fprintf(stderr, "FAIL: the header says %ld blocks needed and there "
                         "are %ld NEED rows\n", h_needed, need_rows);
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

  auto *dut = new Vcadr_disk_harness;

  // ---- the pack side's far ends --------------------------------------------
  //
  // FIXED delays on both faces, so that every move costs the same ticks: see
  // the note at the top.  The varying ones are the property check's.
  Ddr ddr;
  Hp2Slave hp2;
  hp2.ddr = &ddr;
  hp2.vary = false;
  hp2.fixed_ready = 0;
  hp2.fixed_resp = 1;
  hp2.complain = [](const char *w) {
    std::fprintf(stderr, "the pack side's slave: %s\n", w);
  };
  Gp0Master gp0;
  gp0.vary = false;
  gp0.complain = [](const char *w) {
    std::fprintf(stderr, "the pack side's registers: %s\n", w);
  };

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
  // The drive as the trace has attached it: what the DRIVE register holds.
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

    if (d_rst) hp2.reset(dut); else hp2.drive(dut);
    dut->eval();
    hp2.sample(dut);
    dut->clk = 1;
    dut->eval();
    if (!d_rst) hp2.after_edge(dut);
    ++tick;
    live_sel = d_sel;
    live_reg = d_sel ? (int)(d_phys & 3u) : -1;
    if (d_sel && (d_phys >> 2) != (REGS >> 2)) live_reg = -1;
  };

  // Reset, then the pre-roll that puts the spindle in phase, stopping SLACK
  // ticks short of instant zero so that the first group has room in front of
  // the START it is anchored on.
  gp0.quiet(dut);
  for (long i = 0; i < RESET_TICKS; ++i) run_tick(false);
  d_rst = 0;

  // ---- the pack side, as Linux drives it ----------------------------------
  //
  // A register write or read over GP0, and a move of a block over HP2 asked
  // for through the registers and waited out on the status word.  Each is
  // run to completion and then PADDED to its budget, so that it costs the
  // schedule exactly what the dry pass charged for it.
  auto tick_fn = [&]() { run_tick(false); };
  long T_REG = 0, T_FETCH = 0, T_WRITEBACK = 0;
  int overran = 0;
  auto pad_to = [&](long began, long budget, const char *what) {
    if (budget > 0 && tick - began > budget) {
      std::fprintf(stderr,
                   "FAIL: %s took %ld ticks where the pre-roll measured %ld\n",
                   what, tick - began, budget);
      ++overran;
    }
    while (tick < began + budget) run_tick(false);
  };
  auto reg_write = [&](unsigned r, unsigned v) {
    gp0.write(dut, tick_fn, REG_BASE + 4 * r, v);
  };
  auto reg_read = [&](unsigned r) -> unsigned {
    return gp0.read(dut, tick_fn, REG_BASE + 4 * r);
  };
  // The drive, as the DRIVE register carries it.
  auto drive_write = [&]() {
    const long began = tick;
    reg_write(R_DRIVE, (d_present & 0xffu) | (d_ro & 0xffu) << 8 |
                           (d_timed ? 1u << 16 : 0u));
    pad_to(began, T_REG, "a DRIVE register write");
  };
  int pack_bad = 0;
  auto wait_done = [&](const char *what) -> unsigned {
    unsigned st = 0;
    for (int n = 0; n < 400; ++n) {
      st = reg_read(R_CTL);
      if (!(st & ST_BUSY)) break;
    }
    if ((st & ST_BUSY) || !(st & ST_DONE) || (st & (ST_ERROR | ST_REFUSED))) {
      std::fprintf(stderr, "FAIL: %s: the pack side's status is %02x\n", what, st);
      ++pack_bad;
    }
    return st;
  };
  // A block's record, fetched from `at` into `slot` and tagged.
  auto slot_fetch = [&](int slot, unsigned long long at, unsigned tag) {
    const long began = tick;
    reg_write(R_ADDR, (unsigned)at);
    reg_write(R_TAG, tag);
    reg_write(R_SLOT, (unsigned)slot);
    reg_write(R_CTL, CTL_FETCH);
    wait_done("a fetch");
    pad_to(began, T_FETCH, "a fetch");
  };
  // A slot written back to `at`.
  auto slot_writeback = [&](int slot, unsigned long long at) {
    const long began = tick;
    reg_write(R_ADDR, (unsigned)at);
    reg_write(R_SLOT, (unsigned)slot);
    reg_write(R_CTL, CTL_WRITE);
    wait_done("a write-back");
    pad_to(began, T_WRITEBACK, "a write-back");
  };
  // A slot's 259 words, as a write-back to a scratch address delivers them:
  // the only way anything outside can see what the store holds.
  unsigned long long scratch_at = 0x03000000ull;
  auto slot_words = [&](int slot, std::vector<unsigned> &into) {
    scratch_at += 0x480;   // 1,152: a record and its pad, 128-aligned
    slot_writeback(slot, scratch_at);
    unsigned w[RECORD_WORDS];
    ddr.record(scratch_at, w);
    into.assign(w, w + RECORD_WORDS);
  };

  // The budgets, measured on the scratch slot and a scratch record: one
  // register write, one fetch, one write-back.  The scratch slot is then
  // taken away so that no walk can find it.
  {
    const long t0 = tick;
    reg_write(R_DRIVE, 0);
    T_REG = tick - t0;
    unsigned w[RECORD_WORDS];
    for (int i = 0; i < RECORD_WORDS; ++i) w[i] = 0xC0DE0000u + (unsigned)i;
    const unsigned long long at = 0x03F00000ull;
    ddr.place(at, w);
    const long t1 = tick;
    // A tag no row can name: cylinder 4095, which is off every pack.
    slot_fetch(SCRATCH, at, 0x0FFFFFFFu);
    T_FETCH = tick - t1;
    const long t2 = tick;
    slot_writeback(SCRATCH, at + 0x800);
    T_WRITEBACK = tick - t2;
    unsigned back[RECORD_WORDS];
    ddr.record(at + 0x800, back);
    for (int i = 0; i < RECORD_WORDS; ++i)
      if (back[i] != w[i]) {
        std::fprintf(stderr, "FAIL: the pre-roll's round trip lost word %d\n", i);
        return 1;
      }
    reg_write(R_SLOT, SCRATCH);
    reg_write(R_CTL, CTL_TAKE);
    wait_done("the take-away");
    if (pack_bad) return 1;
    // The pre-roll's own moves are not the trace's.
    hp2.aw_count = hp2.w_count = hp2.b_count = hp2.ar_count = hp2.r_count = 0;
    hp2.bursts = 0;
    ddr.reads = ddr.writes = 0;
  }

  while (tick < K - SLACK) run_tick(false);

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
  // the address a tick ahead of the request; the second raises it, which is
  // THE INSTANT OF THE STORE --- the request the controller latches, and the
  // tick every timer it loads is measured from; the third and fourth are the
  // two ticks the controller holds the store for, so that a read on the tick
  // after sees the registers written.  `rtl/cadr_disk_controller.sv` loads
  // its timers two ticks short for exactly this hold, and the trace's
  // tick-sharp samples of them are what say the two agree.
  auto do_write = [&](int reg, unsigned v) {
    d_sel = 1; d_rq = 0; d_wr = 1; d_phys = REGS | (unsigned)reg; d_wdata = v;
    run_tick(false);
    d_rq = 1;
    run_tick(false);
    run_tick(false);
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
  long ex_counter = 0, checked_counter = 0;
  long ex_charged = 0;
  long dm_starts = 0, track_starts = 0, starts = 0, unanchored_starts = 0;
  long groups = 0, shared_groups = 0;
  long full_timeouts = 0, hangs = 0;
  long blk_loaded = 0, blk_compared = 0, blocks_needed = 0;
  std::set<unsigned> resident;   // the blocks the pack side has been given
  long pages_compared = 0, page_words = 0;
  unsigned counters_seen = 0;   // a bit a block-counter value
  unsigned codes_seen = 0;      // a bit a command code
  unsigned chan_bits_seen = 0;  // a bit a channel status bit ever compared
  long seeks_timed = 0, attentions = 0, any_attentions = 0;
  long seek_errors = 0, faults = 0, read_onlys = 0;
  int bad = 0;

  // Where each block of the track under the head sits in the store, taken
  // from the `BLK` rows as they load it: the property check after the trace
  // reads all seventeen back through the seam.
  std::vector<int> trk_slot(17, -1);
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

    ++checked_lma;
    if (lma != r.lma) fail(r, "the last memory address", lma, r.lma);
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
  // **A START HAS TO LAND ON ITS OWN TICK ONLY WHERE THE TRACE CAN TELL ONE
  // TICK FROM ANOTHER ABOUT IT**, and that is a property of the trace and not
  // of the command. The generator's way of asking a tick-resolution question
  // is a pair of instants FIVE NANOSECONDS apart --- `grid_before(t)` and
  // `grid_at(t)`, the countdown having to reach zero between them --- so a
  // START is anchoring exactly when such a pair follows it before the next
  // START. The two seeks are asked that way, and so is the 2.56 s timeout;
  // a transfer's access time is asked a SECTOR_NS at a time, 193,690 ticks,
  // and a group placed to make its START exact is 50 ticks long.
  //
  // **THIS IS WHAT WENT WRONG AT 69a2246 AND IT IS A CHECK GETTING WEAKER,
  // NOT A HOLE.** `loads_timer` gained the transfer codes when the channel
  // began charging `access_ns`, so the group at 2,658,399,985 --- sixteen
  // rows ending in a timed Read --- became anchored on its LAST row, and the
  // backward relaxation below then pulled the lone `grid_before` sample at
  // 2,658,399,980 fifty-three ticks off its own instant. That sample is the
  // one and only place the trace can see `SEEK_SETTLE_NS` to a tick:
  // `disk-seek-settle-a-tick-short` was caught at 3743cf7 on exactly that
  // row and survived at 69a2246. Measured, by reverting each of the channel
  // slice's four candidate changes in turn: only `loads_timer`'s new cases
  // move it. With the rule below the START gives instead --- it lands as
  // many ticks late as the group is long, and the trace's next question
  // about it is 968,448 ns away --- and the sample keeps its instant.
  std::vector<char> fine(rows.size(), 0);
  {
    auto is_start = [&](size_t k) {
      return rows[k].kind == 'C' && rows[k].wr && rows[k].reg == 3;
    };
    for (size_t k = 0; k < rows.size(); ++k) {
      if (!is_start(k)) continue;
      long prev = -1;
      for (size_t e = k + 1; e < rows.size(); ++e) {
        if (is_start(e)) break;
        if (rows[e].now == prev) continue;
        if (prev >= 0 && rows[e].now - prev == 5) { fine[k] = 1; break; }
        prev = rows[e].now;
      }
    }
  }

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
            // Four ticks, and the instant is the second: the request.
            off += 4;
            dry_sel = 1; dry_reg = r.reg;
            long settle = off - 2;
            if (first_settle < 0) first_settle = settle;
            if (r.reg == 0) dry_cmd = r.wdata;
            if (r.reg == 3) {
              unsigned u = (dry_ref_da >> 28) & 7u;
              if (fine[k] && loads_timer(dry_cmd, (dry_present >> u) & 1u,
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
          off += T_REG;
        } else if (r.kind == 'R') {
          if (r.flag) dry_ro |= 1u << (unsigned)(attached_unit < 0 ? 0 : 0);
          else dry_ro = 0;
          off += T_REG;
        } else if (r.kind == 'T') {
          dry_timed = r.flag;
          off += T_REG;
        } else if (r.kind == 'B') {
          // A fetch over the pack side, or a write-back to compare: what the
          // pre-roll measured each to cost.
          off += r.expected ? T_WRITEBACK : T_FETCH;
        }
        // LAY, MEMPAGE, MEMW, PAGE and NEED cost no ticks: memory the program
        // filled, or a fact about the trace.  ATTACH, RO and TIMED are one
        // register write each now that the drive is a register Linux writes.
      }
      // **THE GROUP IS ANCHORED ON THE LAST START THAT LOADS A TIMER THE
      // TRACE GOES ON TO ASK ABOUT A TICK AT A TIME**, and on its first row
      // when it has none. A group of one row then always lands on its own
      // instant, which is what the block-counter sweep and every
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
          drive_write();
          break;
        case 'R':
          if (attached_unit >= 0) {
            if (r.flag) d_ro |= 1u << attached_unit;
            else d_ro &= ~(1u << attached_unit);
          }
          drive_write();
          break;
        case 'T':
          d_timed = r.flag;
          drive_write();
          break;
        // A block the START before this row read off the pack: it has to be
        // resident, put there by a `BLK` row, or the trace is asking for a
        // transfer the store cannot have served.
        case 'N':
          ++blocks_needed;
          if (!resident.count(r.lba)) {
            fail(r, "a block the transfer needed and no BLK row put on the pack side",
                 r.lba, 0);
          }
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
          break;
        // The pack.  A `load` or `lay` row is what a formatter put there: its
        // record goes into the modelled DDR at the row's address and the
        // fabric is told to fetch it.  A `write` row is what a transfer left:
        // the fabric is told to write the slot back to the row's address ---
        // a fresh one, poisoned --- and the record there must be these words.
        case 'B': {
          const unsigned tag = ((unsigned)r.cyl << 16) |
                               ((unsigned)r.head << 8) | (unsigned)r.blk;
          if (r.cyl == 0 && r.head == 0 && r.blk < 17) trk_slot[r.blk] = r.slot;
          if (r.expected) {
            ++blk_compared;
            const unsigned pad_before = ddr.pad(r.at);
            slot_writeback(r.slot, r.at);
            unsigned got[RECORD_WORDS];
            ddr.record(r.at, got);
            if (got[ST_HEADER] != r.page) fail(r, "the block's header", got[ST_HEADER], r.page);
            if (got[ST_HCK] != r.addr) fail(r, "the block's header checkword", got[ST_HCK], r.addr);
            if (got[ST_DCK] != r.word) fail(r, "the block's data checkword", got[ST_DCK], r.word);
            for (int w = 0; w < 256 && !bad; ++w) {
              if (got[w] != bulk[r.words + w]) {
                fail(r, "a word of the block the transfer wrote", got[w],
                     bulk[r.words + w]);
                std::fprintf(stderr, "  slot %d word %d\n", r.slot, w);
              }
            }
            if (ddr.pad(r.at) != pad_before)
              fail(r, "the pad after the record, which a write-back must not touch",
                   ddr.pad(r.at), pad_before);
          } else {
            ++blk_loaded;
            unsigned rec[RECORD_WORDS];
            for (int w = 0; w < 256; ++w) rec[w] = bulk[r.words + w];
            rec[ST_HEADER] = r.page;
            rec[ST_HCK] = r.addr;
            rec[ST_DCK] = r.word;
            ddr.place(r.at, rec);
            slot_fetch(r.slot, r.at, tag);
          }
          resident.insert(r.lba);
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
              // `tick - 2`: the request's tick, the last two ticks of the
              // write being the controller's hold.
              if (getenv("DISK_DEBUG"))
                std::fprintf(stderr, "START row %ld cmd %o tick %ld want %ld\n",
                             r.n, lastcmd & 017u, tick - 2, rows[i].now / 5 + K + turns);
              if (tick - 2 != rows[i].now / 5 + K + turns) ++unanchored_starts;
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
              if (present && !((code == 011u || code == 013u) && ro)) {
                if (track_code(code)) {
                  ++track_starts;
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
            }
            ++checked_read;
            if ((v ^ r.rdata) & mask) fail(r, "the read-back", v, r.rdata);
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

  // =======================================================================
  // THE TRACK, HELD TO ITSELF
  // =======================================================================
  //
  // A property check with no reference trace behind it, in the shape
  // `cadr_memory_path.sv`'s arbiter check has: what is asserted is a
  // property --- the serialiser and the parser are inverses over a whole
  // track --- and the numbers come from the STORE, which the trace's `BLK`
  // rows filled and nothing in the DUT ever wrote.
  //
  // **WHY IT IS NEEDED AND WHAT IT DOES NOT DO.** The trace reads three
  // pages of a Read All and lays two sectors of a Write All, which is 3,072
  // bytes of a 20,160-byte track; those five rows are what anchor each half
  // to muir. This reaches the other 17,088 --- the fifteenth to seventeenth
  // sectors, the 372-byte leftover the index closes, and the wrap back to
  // the start --- and it holds the two halves to EACH OTHER. Neither can
  // stand alone: a round trip cannot see a serialiser and a parser wrong in
  // inverse ways, and the trace cannot see anything past byte 3,072.
  long sc_bytes = 0, sc_wrap = 0, sc_slots = 0, sc_stops = 0;
  if (!bad && !stuck) {
    // Twenty pages: a track is 5,040 words and this is 5,120, so the last
    // eighty words are the stream coming back round --- "the track is read
    // round and round --- the command does not advance the head".
    const unsigned SC_PAGES = 20;
    const unsigned SC_BASE  = 0x100000u;   // 256-aligned, and inside the 22
    const unsigned SC_CLP   = 0x110000u;   //   bits a CCW carries
    const unsigned SC_B2    = 0x120000u;
    const unsigned SC_CLP2  = 0x111000u;
    const long SECTOR = 1164, TRACK = 20160, BPT = 17;

    for (int b = 0; b < 17; ++b)
      if (trk_slot[b] < 0) {
        std::fprintf(stderr,
                     "FAIL: the trace never loaded block %d of cylinder 0 "
                     "head 0, so the track cannot be checked\n", b);
        return 1;
      }
    if (SC_BASE + SC_PAGES * 256u > (unsigned)h_memory ||
        SC_B2 + 1024u > (unsigned)h_memory) {
      std::fprintf(stderr, "FAIL: the property check wants more memory than "
                           "the trace's %ld words\n", h_memory);
      return 1;
    }

    // The drive is on unit 0, its pack writable, and its time NOT charged:
    // a track is a whole revolution and this check is about bytes.
    d_present |= 1u;
    d_ro      = 0;
    d_timed   = 0;

    auto ccws = [&](unsigned clp, unsigned page0, int n) {
      for (int k = 0; k < n; ++k)
        mem[clp + (unsigned)k] =
            ((page0 + (unsigned)k * 256u) & 0x003fff00u) |
            ((k + 1 < n) ? 1u : 0u);
    };
    auto command = [&](unsigned code, unsigned clp, unsigned da) {
      do_write(0, code);
      do_write(1, clp);
      do_write(2, da);
      do_write(3, 0);
      settle_walk();
    };
    auto tbyte = [&](unsigned base, long at) -> unsigned {
      return (mem[base + (unsigned)(at >> 2)] >> (8 * (at & 3))) & 0xffu;
    };
    auto poke_byte = [&](unsigned base, long at, unsigned v) {
      unsigned &w = mem[base + (unsigned)(at >> 2)];
      const int sh = 8 * (int)(at & 3);
      w = (w & ~(0xffu << sh)) | ((v & 0xffu) << sh);
    };
    auto say = [&](const char *what, unsigned got, unsigned want) {
      std::fprintf(stderr, "the track, held to itself: %s is %08x, "
                           "wanting %08x\n", what, got, want);
      ++bad;
    };
    // Every error bit the channel can raise, and not-active with it.
    auto quiet = [&](const char *what) {
      unsigned st = do_read(0);
      if ((st & CHAN) || !(st & 1u))
        say(what, st & (CHAN | 1u), 1u);
    };

    // ---- the seventeen blocks as the trace left them ---------------------
    //
    // Read out of the store the only way there is: a write-back over the
    // pack side to a scratch record, and the record read.
    std::vector<std::vector<unsigned>> orig(17, std::vector<unsigned>(259));
    auto snap = [&](int b, std::vector<unsigned> &into) {
      slot_words(trk_slot[b], into);
    };
    for (int b = 0; b < 17; ++b) snap(b, orig[b]);

    // What `sector_image_laid` puts at byte `p` of the sector holding block
    // `b`, written out here from muir's `disk_unit::format` so that the RTL
    // and this are two independent expressions of one table. The trace's
    // three `PAGE` rows are what say this one agrees with muir.
    auto want_byte = [&](long at) -> unsigned {
      if (at >= BPT * SECTOR) return 0xffu;          // the leftover
      const long b = at / SECTOR, p = at % SECTOR;
      const std::vector<unsigned> &o = orig[b];
      if (p < 61) return 0xffu;
      if (p == 61) return 0177u;                     // SYNC
      if (p < 66) return (o[256] >> (8 * (p - 62))) & 0xffu;
      if (p < 70) return (o[257] >> (8 * (p - 66))) & 0xffu;
      if (p < 90) return 0xffu;                      // VFO RELOCK
      if (p == 90) return 0177u;                     // SYNC
      if (p == 91) return 0377u;                     // PAD
      if (p < 1116) return (o[(p - 92) / 4] >> (8 * ((p - 92) % 4))) & 0xffu;
      if (p < 1120) return (o[258] >> (8 * (p - 1116))) & 0xffu;
      return 0xffu;                                  // POSTAMBLE
    };

    // ---- Read All, a whole track and eighty words of the next -----------
    for (unsigned w = 0; w < SC_PAGES * 256u; ++w)
      mem[SC_BASE + w] = 0xA5A50000u ^ (w * 0x9E3779B1u);
    ccws(SC_CLP, SC_BASE, (int)SC_PAGES);
    command(002u, SC_CLP, 0u);
    quiet("the status after a Read All of a whole track");
    {
      unsigned got = do_read(1), w = SC_BASE + (SC_PAGES - 1) * 256u + 255u;
      if (got != w) say("the last memory address after a Read All", got, w);
    }
    for (long at = 0; at < TRACK; ++at) {
      ++sc_bytes;
      unsigned got = tbyte(SC_BASE, at), w = want_byte(at);
      if (got != w) {
        std::fprintf(stderr,
                     "the track, held to itself: byte %ld of the track "
                     "(sector %ld byte %ld) is %02x, wanting %02x\n",
                     at, at / SECTOR, at % SECTOR, got, w);
        ++bad;
        break;
      }
    }
    // "a list longer than a track comes back to where it started"
    for (long at = TRACK; at < (long)SC_PAGES * 1024 && !bad; ++at) {
      ++sc_wrap;
      unsigned got = tbyte(SC_BASE, at), w = tbyte(SC_BASE, at - TRACK);
      if (got != w) {
        std::fprintf(stderr,
                     "the track, held to itself: byte %ld, past the end of "
                     "the track, is %02x where byte %ld is %02x\n",
                     at, got, at - TRACK, w);
        ++bad;
      }
    }

    // ---- Write All of exactly those bytes back --------------------------
    //
    // **WITH A DECOY IN THE FIRST SECTOR'S PREAMBLE.** `after_sync` wants a
    // zero after at least SIXTY-FOUR ones, and on a well-formed sector the
    // count cannot matter: the sector opens with 488 ones and the first zero
    // in it is the sync's, so a parser taking the first zero after ANY run
    // finds the same place. So the preamble is given four runs that are too
    // short --- eight ones then a zero, sixteen, thirty-two, forty-eight ---
    // and a parser that accepts after fewer than forty-nine takes its header
    // out of the preamble. Ones enough for the real sync are still there:
    // 380 before it and seven in it.
    //
    // **FORTY-NINE AND NOT SIXTY-FOUR IS THE HONEST FIGURE**, and it is a
    // real equivalence rather than a gap in the decoy: on a sector this
    // format lays down, any threshold between 49 and 488 finds the same
    // zero, so no stimulus made of well-formed sectors can tell 64 from 63.
    // What can be told is a threshold low enough to fire inside a run this
    // format leaves, and that is what is tested.
    {
      unsigned char dec[14];
      for (int i = 0; i < 14; ++i) dec[i] = 0xff;
      const int zeros[4] = {8, 25, 58, 107};
      for (int z = 0; z < 4; ++z)
        dec[zeros[z] / 8] = (unsigned char)(dec[zeros[z] / 8] &
                                            ~(1u << (zeros[z] % 8)));
      for (int i = 0; i < 14; ++i) poke_byte(SC_BASE, i, dec[i]);
    }
    command(013u, SC_CLP, 0u);
    quiet("the status after a Write All of a whole track");
    {
      unsigned got = do_read(1), w = SC_BASE + (SC_PAGES - 1) * 256u + 255u;
      if (got != w) say("the last memory address after a Write All", got, w);
    }
    std::vector<unsigned> now(259);
    auto same = [&](int b, const std::vector<unsigned> &w, const char *why) {
      snap(b, now);
      ++sc_slots;
      for (int k = 0; k < 259 && !bad; ++k)
        if (now[k] != w[k]) {
          std::fprintf(stderr,
                       "the track, held to itself: %s --- block %d %s is "
                       "%08x, wanting %08x\n", why, b,
                       k < 256 ? "word" : (k == 256 ? "header"
                                        : (k == 257 ? "header checkword"
                                                    : "data checkword")),
                       now[k], w[k]);
          if (k < 256) std::fprintf(stderr, "  word %d\n", k);
          ++bad;
        }
    };
    for (int b = 0; b < 17 && !bad; ++b)
      same(b, orig[b], "the round trip changed the pack");

    // ---- a chunk that will not parse stops the track and not the walk ----
    //
    // `lay_down_track` breaks out of its loop where `parse_sector` answers
    // `None`, and `write_all_bytes` has already walked the WHOLE list by
    // then --- so the sectors before the bad one are laid, the ones after it
    // are not, and register 1 still holds the last word of the last page.
    // Two shapes of `None`, because they leave the parser in different
    // places. The first is a chunk with no zero after ones at all, which
    // `after_sync` walks to the end of and gives up on.
    //
    // The second is `take_bits` answering `None` --- the data's sync so late
    // that the data and its checkword do not fit in what is left of the
    // chunk --- and it is the one branch that has to decide BEFORE a word
    // goes into the store, because everything after it writes. So it is
    // asked ON THE BOUNDARY and one bit either side of it: a sync at bit
    // 1,080 leaves exactly 8,232 bits and must be laid, and one at 1,081
    // leaves 8,231 and must lay nothing. **The magnitude is swept because
    // the boundary is where a fence-post is**, and the pair costs one chunk
    // more than either alone.
    auto chunk_from = [&](unsigned dst, int dc, unsigned src, int sc) {
      for (int w = 0; w < 291; ++w)
        mem[dst + (unsigned)(dc * 291 + w)] = mem[src + (unsigned)(sc * 291 + w)];
    };
    // The chunk that is all ones but for a sync's zero at 495 and a second
    // at `z`: the header and its checkword are then taken from bits 496 to
    // 559, all ones, and the data from `z + 9` --- so what a parse of it
    // lays is a block of nothing but ones, header, checkwords and all.
    auto ones_chunk = [&](int dc, int z) {
      for (int w = 0; w < 291; ++w) mem[SC_B2 + (unsigned)(dc * 291 + w)] = 0xFFFFFFFFu;
      mem[SC_B2 + (unsigned)(dc * 291 + 495 / 32)] &= ~(1u << (495 % 32));
      mem[SC_B2 + (unsigned)(dc * 291 + z / 32)]   &= ~(1u << (z % 32));
    };
    std::vector<unsigned> all_ones(259, 0xFFFFFFFFu);
    for (int pass = 0; pass < 2 && !bad; ++pass) {
      for (unsigned w = 0; w < 1024u; ++w) mem[SC_B2 + w] = 0xFFFFFFFFu;
      if (pass == 0) {
        chunk_from(SC_B2, 0, SC_BASE, 5);              // block 5's sector
        for (int w = 0; w < 291; ++w) mem[SC_B2 + 291u + (unsigned)w] = 0u;
      } else {
        ones_chunk(0, 1079);   // the data's sync at 1,080: 8,232 bits left
        ones_chunk(1, 1080);   // at 1,081: 8,231, and `take_bits` says no
      }
      chunk_from(SC_B2, 2, SC_BASE, 3);
      ccws(SC_CLP2, SC_B2, 4);
      command(013u, SC_CLP2, 0u);
      ++sc_stops;
      quiet("the status after a Write All whose second sector will not parse");
      {
        unsigned got = do_read(1), w = SC_B2 + 3u * 256u + 255u;
        if (got != w)
          say("the last memory address after a track that stopped laying",
              got, w);
      }
      // Block 0 took the first chunk; blocks 1 and 2, and everything after
      // them, are as the round trip left them.
      same(0, pass == 0 ? orig[5] : all_ones, "the first sector was not laid");
      for (int b = 1; b < 17 && !bad; ++b)
        same(b, orig[b], "the track went on after a chunk that will not parse");
    }
  }

  delete dut;

  if (stuck) return 1;
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches\n", bad);
    return 1;
  }
  if (pack_bad || overran || hp2.bad || gp0.bad) {
    std::fprintf(stderr, "FAIL: the pack side: %d moves not done, %d over "
                         "budget, %d protocol errors, %d register errors\n",
                 pack_bad, overran, hp2.bad, gp0.bad);
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
  want("blocks fetched into the store over the pack side", blk_loaded);
  want("blocks a transfer wrote, written back and compared", blk_compared);
  want("blocks a transfer needed", blocks_needed);
  want("pages compared word for word", pages_compared);
  want("tracks read out and compared byte for byte", sc_bytes);
  want("bytes of a track read past its end", sc_wrap);
  want("blocks compared after the round trip", sc_slots);
  want("tracks stopped by a chunk that will not parse", sc_stops);
  want("Read Alls and Write Alls", track_starts);
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
      "    %ld pages compared word for word (%ld words), %ld blocks fetched\n"
      "      into the store over the pack side, %ld blocks a transfer wrote\n"
      "      written back over it and compared, %ld blocks a transfer needed\n"
      "      each resident when it ran\n"
      "    %ld ticks spent walking\n"
      "  the pack side, at fixed delays: %ld AXI bursts, %ld read beats, %ld\n"
      "    write beats, %ld register writes and %ld reads; a fetch %ld ticks,\n"
      "    a write-back %ld, a register write %ld\n"
      "  the track, held to itself as well as to muir:\n"
      "    %ld bytes of a whole track serialised out of the store and\n"
      "      compared against disk_unit::format one byte at a time, %ld more\n"
      "      read past its end and found to be the start of it again\n"
      "    %ld blocks written back over the pack side after the parser put the\n"
      "      same bytes back on the pack, with a preamble decoy in the first\n"
      "      sector that a parser accepting after fewer than 49 ones takes\n"
      "    %ld tracks stopped by a chunk that will not parse, the walk\n"
      "      finishing anyway\n"
      "  exempt, and this is the whole of it:\n"
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
      pages_compared, page_words, blk_loaded, blk_compared, blocks_needed,
      walk_ticks, hp2.bursts, hp2.r_count, hp2.w_count, gp0.writes, gp0.reads,
      T_FETCH, T_WRITEBACK, T_REG,
      sc_bytes, sc_wrap, sc_slots, sc_stops,
      ex_counter, checked_counter, ex_charged,
      shared_groups, unanchored_starts, realignments);
  return 0;
}
