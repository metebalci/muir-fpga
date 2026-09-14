// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Arty A7-100's memory path, against a model of the controller it drives.
//
// WHAT IS BEING HELD TO WHAT.  There is no muir reference for any of this ---
// nothing in MIT's drawings is a DDR3 controller, and `busint::MemoryBoard`
// models a board of 4116s refreshing itself.  So this is held to what it has
// to be true of, which is the same list `cadr_axi_master`'s check holds its
// module to, plus the two things that are new on this board:
//
//   1. A read returns what a write put there, with the shadow kept HERE and
//      keyed by the address the STIMULUS asked for --- never by anything the
//      design under test computed.  A shadow keyed off the design moves with
//      the bug: a path that drops an address bit writes and reads the same
//      wrong place and agrees with itself.
//   2. A write lands in ITS OWN LANE of the sixteen-byte block and in no
//      other.  That is the fault this family of module actually makes, and
//      the model's poison --- injective in the address, so a neighbour's word
//      is recognisably a neighbour's --- is what makes it visible.
//   3. The controller's own protocol, watched in the model: an aligned block
//      address, a write burst that ends, a command held still until it is
//      taken, and write data that never arrives more than two user clocks
//      after its command.
//   4. **TWO CLOCKS**, which is what is new here.  The machine's tick and the
//      controller's user clock have no fixed relationship, so every
//      transaction is started at a different phase of one against the other,
//      and the run is done twice at two different ratios.  A crossing that
//      works at one phase and not another is the fault a single ratio hides.
//   5. The debugger's window, which on this board is the only way into memory
//      from outside the machine: its scan register, its command, and that a
//      machine transaction and a window transaction in flight together both
//      complete and neither takes the other's answer.
//
// **THE READ LATENCY IS SWEPT AND THE BACKPRESSURE IS DELIBERATE.**  A model
// that always answers at once and never refuses is a model of a memory nobody
// has, and this project has already recorded what a stimulus more polite than
// the real consumer tests: nothing.

#include <cstdio>
#include <cstdlib>
#include <map>
#include <vector>

#include "Vcadr_a7_mem_harness.h"
#include "verilated.h"

namespace {

Vcadr_a7_mem_harness *dut;
long ps = 0;          // the model's own time, in nanoseconds
int clk_half = 5;     // the machine's tick is 10 ns
int ui_half = 6;      // the controller's user clock, swept below
long clk_next = 0, ui_next = 0;
int bad = 0;

// The machine's reservation, and the board's translation of it: the map's
// 128 MB at 0x1800_0000 is the TOP half of this board's 256 MB.
const unsigned RESERVED_BASE = 0x18000000u;
unsigned DdrByte(unsigned mem_addr) {
  return 0x08000000u | (mem_addr & 0x07FFFFFFu);
}
// What the model answers for a word nothing has written.
unsigned Poison(unsigned mem_addr) {
  return 0xB0000000u ^ ((DdrByte(mem_addr) & 0x0FFFFFFFu) >> 2);
}

void Step() {
  ++ps;
  if (ps >= clk_next) {
    dut->clk = !dut->clk;
    clk_next = ps + clk_half;
  }
  if (ps >= ui_next) {
    dut->ui_clk = !dut->ui_clk;
    ui_next = ps + ui_half;
  }
  dut->eval();
}

void Steps(int n) {
  for (int i = 0; i < n; ++i) Step();
}

int Fail(const char *what, unsigned got, unsigned want) {
  std::fprintf(stderr, "ns %ld: %s is 0x%08x, expected 0x%08x\n", ps, what, got,
               want);
  ++bad;
  return 1;
}

// One transaction on the machine's own port, driven the way `cadr_xbus_ddr`
// drives it: the address and the data stand before the request goes up, the
// request is HELD until the word is done, and it is let go afterwards.  **A
// stimulus that dropped the request the instant `mem_done` appeared would be
// more polite than the real consumer and would test less.**
// `hold_ns` is how long the controller refuses, MEASURED FROM THE REQUEST and
// not from before it.  **The first draft set the refusal up and took it down
// again before raising the request**, so the design never once had to wait ---
// a stimulus more polite than the real consumer, and the mutation written to
// break UG586's write-data rule was then caught by a side effect instead of by
// the rule.  The refusal now stands across the transaction and is lifted under
// it.
bool Access(bool write, unsigned addr, unsigned wdata, unsigned *rdata,
            long limit = 20000, int hold_cmd = 0, int hold_wdata = 0,
            int hold_ns = 0) {
  dut->mem_addr = addr;
  dut->mem_wdata = wdata;
  dut->mem_write = write;
  dut->hold_cmd = hold_cmd;
  dut->hold_wdata = hold_wdata;
  Steps(3);
  dut->mem_req = 1;
  long t = 0;
  while (!dut->mem_done) {
    Step();
    if (t == hold_ns) {
      dut->hold_cmd = 0;
      dut->hold_wdata = 0;
    }
    if (++t > limit) {
      std::fprintf(stderr, "ns %ld: no answer for %s at 0x%08x\n", ps,
                   write ? "a write" : "a read", addr);
      ++bad;
      dut->mem_req = 0;
      return false;
    }
  }
  if (rdata) *rdata = dut->mem_rdata;
  bool err = dut->mem_error;
  dut->mem_req = 0;
  while (dut->mem_done) Step();
  Steps(2);
  return err;
}

unsigned Peek(unsigned mem_addr) {
  dut->peek_addr = DdrByte(mem_addr);
  dut->eval();
  return dut->peek_data;
}

// ---------------------------------------------------------- the JTAG window
//
// One data register of 160 bits on a `BSCANE2` user chain, scanned the way
// Vivado's `scan_dr_hw_jtag` scans one: bit zero first in both directions, so
// a bit number here is the bit number the host script uses.
const int DR_BITS = 160;

struct Scan {
  unsigned out[5];  // what came back, 160 bits as five words
};

Scan ScanDr(const unsigned in[5]) {
  Scan s{};
  dut->jtag_sel = 1;
  // CAPTURE-DR: one clock of DRCK with capture high.
  dut->jtag_capture = 1;
  dut->jtag_shift = 0;
  dut->jtag_drck = 0;
  Steps(2);
  dut->jtag_drck = 1;
  Steps(2);
  dut->jtag_drck = 0;
  dut->jtag_capture = 0;
  Steps(2);
  // SHIFT-DR.
  dut->jtag_shift = 1;
  for (int i = 0; i < DR_BITS; ++i) {
    dut->jtag_tdi = (in[i / 32] >> (i % 32)) & 1;
    dut->eval();
    if (dut->jtag_tdo) s.out[i / 32] |= (1u << (i % 32));
    dut->jtag_drck = 1;
    Steps(2);
    dut->jtag_drck = 0;
    Steps(2);
  }
  dut->jtag_shift = 0;
  // UPDATE-DR.  **HELD FOR TEN OF THE MACHINE'S TICKS AND NOT ONE.**  The
  // fabric synchronises this pulse into its own clock with three registers, so
  // a pulse shorter than a few ticks can be missed --- and a real test access
  // port runs at a few megahertz, where this is microseconds.  Written short
  // the first time, it made the window miss about one command in ten and read
  // as a fabric fault.
  dut->jtag_update = 1;
  Steps(100);
  dut->jtag_update = 0;
  Steps(100);
  return s;
}

int go_bit = 0;
int arm_bit = 0;

// Ask the window for one transaction and collect the answer with a second
// scan, which is what the host script does: a data register scan is both
// halves at once and the fabric has done the work in between.
unsigned WindowAccess(bool write, unsigned addr, unsigned wdata,
                      bool *err_out) {
  unsigned in[5] = {0, 0, 0, 0, 0};
  go_bit ^= 1;
  in[0] = wdata;
  in[1] = addr;
  in[2] = (write ? 1u : 0u) | ((unsigned)go_bit << 1) |
          ((unsigned)arm_bit << 2);
  ScanDr(in);
  // The fabric has microseconds; give it a few hundred nanoseconds.
  Steps(2000);
  // The same command word again, `go` unchanged, so that the re-scan is
  // harmless --- which is the property that lets a host poll.
  Scan s = ScanDr(in);
  if (err_out) *err_out = (s.out[3] >> 2) & 1;
  unsigned ident = s.out[4];
  if (ident != 0x4D454D57u) {
    std::fprintf(stderr, "ns %ld: the window's IDENT is 0x%08x, not MEMW\n", ps,
                 ident);
    ++bad;
  }
  return s.out[0];
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vcadr_a7_mem_harness;

  long writes = 0, reads = 0, reads_checked = 0, window_ops = 0;
  long lanes_checked = 0, neighbours_checked = 0, refused = 0;
  long contended = 0, stalled_cmd = 0, stalled_wdata = 0;

  // The two ratios.  `ui_half` 6 makes the controller's clock 83.3 MHz against
  // the machine's 100, and 7 makes it 71.4 --- neither is a whole ratio of the
  // other, so each transaction starts at a different phase.
  for (int cfg = 0; cfg < 2; ++cfg) {
    ui_half = cfg == 0 ? 6 : 7;
    ps = 0;
    clk_next = 0;
    ui_next = 0;
    go_bit = 0;
    arm_bit = 0;

    dut->clk = 0;
    dut->ui_clk = 0;
    dut->rst = 1;
    dut->ui_rst = 1;
    dut->mem_req = 0;
    dut->mem_write = 0;
    dut->mem_addr = 0;
    dut->mem_wdata = 0;
    dut->jtag_drck = 0;
    dut->jtag_sel = 0;
    dut->jtag_shift = 0;
    dut->jtag_capture = 0;
    dut->jtag_update = 0;
    dut->jtag_tdi = 0;
    dut->calib_done = 1;
    dut->prove_has_run = 0;
    dut->prove_matched = 0;
    dut->hold_cmd = 0;
    dut->hold_wdata = 0;
    dut->read_latency = 3;
    dut->peek_addr = 0;
    Steps(200);
    dut->rst = 0;
    dut->ui_rst = 0;
    Steps(200);

    // **THE TWO RUNS USE DIFFERENT ADDRESSES, BECAUSE THE MEMORY IS NOT
    // CLEARED BETWEEN THEM.**  A model that forgot everything at each reset
    // would be a model of a memory nobody has, and the first draft of this
    // check read the first run's words back in the second and called them
    // corruption.  Eight megabytes apart is far enough that the model's own
    // index and tag both differ.
    const unsigned CFG_OFF = (unsigned)cfg * 0x00800000u;

    std::map<unsigned, unsigned> shadow;  // keyed by the STIMULUS's address
    unsigned seed = 12345u + cfg;
    auto lcg = [&seed]() {
      seed = seed * 1664525u + 1013904223u;
      return seed >> 8;
    };

    // ---- 1. writes and reads, at every phase, with the controller refusing
    for (int op = 0; op < 400; ++op) {
      // Inside the machine's own reservation, and drawn from a SMALL SET OF
      // ADDRESSES spread by an odd stride.  Small, so that a read usually
      // lands on something a write put there --- a run whose reads mostly hit
      // never-written words would be checking the model's poison and not the
      // path.  Odd, because 452 bytes is twenty-eight blocks and one lane, so
      // consecutive slots move the block AND the lane and every one of the
      // four lanes is exercised.
      unsigned slot = lcg() % 96;
      unsigned addr = RESERVED_BASE + CFG_OFF + slot * 452u;
      dut->read_latency = op % 12;
      // The controller refuses, and goes on refusing while the design waits.
      int hc = (op % 5) == 0;
      int hw = (op % 7) == 0;
      // **LONG ENOUGH TO BE A REFUSAL AND NOT A HICCUP.**  Two hundred to six
      // hundred nanoseconds is sixteen to forty-eight of the controller's own
      // clocks, where thirty was two and a half --- and UG586's write-data
      // rule is broken at THREE, so a shorter refusal cannot tell a design
      // that keeps the rule from one that does not.
      int hns = (hc || hw) ? 200 + (op % 400) : 0;
      if (hc) ++stalled_cmd;
      if (hw) ++stalled_wdata;
      if ((op % 3) == 0) {
        unsigned v = lcg() | 0x80000001u;
        Access(true, addr, v, nullptr, 20000, hc, hw, hns);
        shadow[addr] = v;
        ++writes;
      } else {
        unsigned got = 0;
        Access(false, addr, 0, &got, 20000, hc, hw, hns);
        ++reads;
        auto it = shadow.find(addr);
        unsigned want = it == shadow.end() ? Poison(addr) : it->second;
        if (it != shadow.end()) ++reads_checked;
        if (got != want) Fail("a read", got, want);
      }
    }

    // ---- 2. all four lanes of one block, written differently
    //
    // A lane select stuck at one value collapses the four into one, and the
    // read-back then shows the last word written four times.  That is the
    // fault, and it is invisible to a check that writes one lane.
    {
      unsigned base = RESERVED_BASE + CFG_OFF + 0x0002A000u;  // block aligned
      unsigned v[4] = {0x11223344u, 0x55667788u, 0x99AABBCCu, 0xDDEEFF01u};
      for (int l = 0; l < 4; ++l) Access(true, base + 4 * l, v[l], nullptr);
      for (int l = 0; l < 4; ++l) {
        unsigned got = 0;
        Access(false, base + 4 * l, 0, &got);
        if (got != v[l]) Fail("a lane of a block", got, v[l]);
        ++lanes_checked;
        // ...and the model's own memory says the same, which is what tells a
        // read that compensates for a wrong write from one that is right.
        unsigned in_model = Peek(base + 4 * l);
        if (in_model != v[l]) Fail("the lane in memory", in_model, v[l]);
      }
    }

    // ---- 3. a write disturbs nothing beside it
    {
      unsigned base = RESERVED_BASE + CFG_OFF + 0x0003C000u;
      unsigned v = 0xFACEB00Cu;
      Access(true, base + 8, v, nullptr);  // lane 2 of the block
      for (int l = 0; l < 4; ++l) {
        unsigned got = Peek(base + 4 * l);
        unsigned want = l == 2 ? v : Poison(base + 4 * l);
        if (got != want) Fail("a neighbouring lane", got, want);
        ++neighbours_checked;
      }
      // ...and the blocks either side are untouched, which is what a dropped
      // address bit would show.
      for (int d = -16; d <= 16; d += 32) {
        unsigned a = base + 8 + d;
        unsigned got = Peek(a);
        if (got != Poison(a)) Fail("a neighbouring block", got, Poison(a));
        ++neighbours_checked;
      }
    }

    // ---- 4. an address outside the reservation is refused, not wrapped
    {
      unsigned outside = 0x10000000u;  // below the map's base
      unsigned got = 0;
      bool err = Access(false, outside, 0, &got);
      if (!err) {
        std::fprintf(stderr,
                     "ns %ld: a read outside the reservation was not refused\n",
                     ps);
        ++bad;
      }
      if (got != 0) Fail("the word a refused read gave", got, 0);
      err = Access(true, outside, 0xDEADBEEFu, nullptr);
      if (!err) {
        std::fprintf(stderr,
                     "ns %ld: a write outside the reservation was not "
                     "refused\n",
                     ps);
        ++bad;
      }
      refused += 2;
    }

    // ---- 5. the debugger's window
    {
      unsigned base = RESERVED_BASE + CFG_OFF + 0x00051000u;
      bool err = false;
      // Four lanes again, through the window this time: the host's own poison
      // is what makes a collapsed lane select visible from this side too.
      unsigned v[4] = {0xA1B2C3D4u, 0xE5F60718u, 0x293A4B5Cu, 0x6D7E8F90u};
      for (int l = 0; l < 4; ++l) {
        WindowAccess(true, base + 4 * l, v[l], &err);
        ++window_ops;
      }
      for (int l = 0; l < 4; ++l) {
        unsigned got = WindowAccess(false, base + 4 * l, 0, &err);
        ++window_ops;
        if (got != v[l]) Fail("the window's read", got, v[l]);
        if (err) {
          std::fprintf(stderr, "ns %ld: the window reported an error\n", ps);
          ++bad;
        }
      }
      // ...and the machine sees the same words, which is what says the window
      // and the machine are looking at one memory.
      for (int l = 0; l < 4; ++l) {
        unsigned got = 0;
        Access(false, base + 4 * l, 0, &got);
        if (got != v[l]) Fail("the machine's view of the window's word", got,
                              v[l]);
      }
      // A word the machine wrote, read back through the window.
      Access(true, base + 0x40, 0x0BADF00Du, nullptr);
      unsigned got = WindowAccess(false, base + 0x40, 0, &err);
      ++window_ops;
      if (got != 0x0BADF00Du) Fail("the window's view of the machine's word",
                                   got, 0x0BADF00Du);
    }

    // ---- 6. the two of them at once
    //
    // The machine must win and must still be answered, and the window's own
    // transaction must not take the machine's word or lose its own.
    {
      unsigned ma = RESERVED_BASE + CFG_OFF + 0x00061000u;
      unsigned wa = RESERVED_BASE + CFG_OFF + 0x00062000u;
      Access(true, ma, 0x13579BDFu, nullptr);
      Access(true, wa, 0x2468ACE0u, nullptr);
      for (int k = 0; k < 12; ++k) {
        // **THE CONTROLLER IS TOLD TO TAKE NOTHING FIRST**, which is what makes
        // this a race at all.  A scan takes hundreds of nanoseconds of its own
        // and the window's transaction is over before it ends, so a machine
        // request issued after the scan finds the port free and the two never
        // meet.  Refusing every command holds the window's transaction open
        // until the machine has asked; the refusal is then lifted and both
        // must complete, each with its own word.
        //
        // A race check needs the stimulus that loses the race, and the
        // testbench's convenience speed is the speed at which nothing races.
        dut->hold_cmd = 1;
        unsigned in[5] = {0, 0, 0, 0, 0};
        go_bit ^= 1;
        in[0] = 0;
        in[1] = wa;
        in[2] = ((unsigned)go_bit << 1);
        ScanDr(in);
        // The machine asks while the window owns the port.
        dut->mem_addr = ma;
        dut->mem_wdata = 0;
        dut->mem_write = 0;
        Steps(3);
        dut->mem_req = 1;
        Steps(20 + k * 7);
        dut->hold_cmd = 0;
        long t = 0;
        while (!dut->mem_done) {
          Step();
          if (++t > 20000) {
            std::fprintf(stderr, "ns %ld: the machine got no answer under "
                                 "contention\n", ps);
            ++bad;
            break;
          }
        }
        unsigned got = dut->mem_rdata;
        dut->mem_req = 0;
        while (dut->mem_done) Step();
        Steps(2);
        if (got != 0x13579BDFu) Fail("the machine's word under contention", got,
                                     0x13579BDFu);
        Steps(2000);
        Scan s = ScanDr(in);
        if (s.out[0] != 0x2468ACE0u)
          Fail("the window's word under contention", s.out[0], 0x2468ACE0u);
        ++contended;
      }
    }

    // ---- 7. the protocol flags the model raised, if any
    if (dut->viol_addr_align) {
      std::fprintf(stderr,
                   "FAIL: a command named an address that is not a "
                   "sixteen-byte block, or set the rank bit\n");
      ++bad;
    }
    if (dut->viol_wdf_end) {
      std::fprintf(stderr, "FAIL: a write data beat did not end its burst\n");
      ++bad;
    }
    if (dut->viol_cmd_unstable) {
      std::fprintf(stderr,
                   "FAIL: a command moved while the controller had not taken "
                   "it\n");
      ++bad;
    }
    if (dut->viol_wdata_late) {
      std::fprintf(stderr,
                   "FAIL: write data arrived more than two user clocks after "
                   "its command\n");
      ++bad;
    }

    // ---- 8. the tally
    //
    // It is the one witness on this board that is not on the path the
    // debugger's own words travel, so what it says has to be right.
    {
      unsigned lo = dut->tally & 0xFFFFFFFFu;
      unsigned hi = (unsigned)(dut->tally >> 32);
      if ((lo & 0x80008000u) != 0x00008000u ||
          (hi & 0x80008000u) != 0x00008000u) {
        std::fprintf(stderr,
                     "FAIL: the tally's marker bits read 0x%08x 0x%08x, which "
                     "neither an all-ones nor an all-zeros reading may\n",
                     hi, lo);
        ++bad;
      }
      unsigned answered_reads = lo & 0x7FFFu;
      unsigned answered_writes = (lo >> 16) & 0x7FFFu;
      unsigned asked_reads = hi & 0x7FFFu;
      unsigned asked_writes = (hi >> 16) & 0x7FFFu;
      // **ASKED AND ANSWERED DIFFER BY EXACTLY WHAT WAS REFUSED.**  A request
      // for an address outside the machine's reservation is answered by
      // `cadr_mig_ui` itself and never reaches the controller, so it is asked
      // and not answered --- one read and one write in this run.  Writing the
      // two counts as equal would either fail here or, worse, pass a design
      // that had stopped refusing anything.
      if (asked_reads != answered_reads + 1)
        Fail("the tally's reads", answered_reads + 1, asked_reads);
      if (asked_writes != answered_writes + 1)
        Fail("the tally's writes", answered_writes + 1, asked_writes);
      if (asked_reads == 0 || asked_writes == 0) {
        std::fprintf(stderr, "FAIL: the tally counted nothing\n");
        ++bad;
      }
    }
  }

  if (bad) {
    std::fprintf(stderr, "FAIL: %d disagreement(s)\n", bad);
    return 1;
  }

  const struct {
    const char *what;
    long n;
  } want[] = {{"writes", writes},
              {"reads", reads},
              {"reads matched against an earlier write", reads_checked},
              {"lanes of one block read back", lanes_checked},
              {"neighbours found untouched", neighbours_checked},
              {"addresses outside the reservation refused", refused},
              {"transactions through the debugger's window", window_ops},
              {"contended pairs", contended},
              {"transactions the controller refused a command on", stalled_cmd},
              {"transactions the controller refused write data on",
               stalled_wdata}};
  for (const auto &w : want)
    if (w.n == 0) {
      std::fprintf(stderr, "FAIL: the run has no %s\n", w.what);
      return 1;
    }

  std::printf(
      "ok: the A7's memory path agrees with a model of the controller\n"
      "    two clock ratios, 100 MHz against 83.3 and 71.4\n"
      "    %ld writes and %ld reads, %ld of them matched against a write\n"
      "    %ld lanes of a block and %ld neighbours, all where they belong\n"
      "    %ld addresses outside the reservation refused with a zero word\n"
      "    %ld transactions through the debugger's window, %ld contended\n"
      "    %ld waited on a refused command and %ld on refused write data\n"
      "    the controller's protocol held at every tick: aligned blocks, a\n"
      "    burst that ends, a command held until taken, data never late\n",
      writes, reads, reads_checked, lanes_checked, neighbours_checked, refused,
      window_ops, contended, stalled_cmd, stalled_wdata);
  return 0;
}
