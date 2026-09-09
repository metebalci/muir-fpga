// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The witness, against an AXI3 slave that is not the design.
//
// `rtl/cadr_prove.sv` is the fabric half of the two steps that decide whether
// the memory port works before the machine is put behind it.  On the board its
// other half is a debugger reading and writing DDR --- an observer outside the
// design, and the whole reason those steps are worth doing.  Here that
// observer is this file: a 64-bit AXI3 slave with a model memory the DUT never
// touches except through the port, so a witness that is wrong about the
// address, the word, the lane or the strobes cannot agree with it.
//
// IT IS THE HARNESS AND NOT THE MODULE THAT IS INSTANTIATED, deliberately.
// `tb/cadr_prove_harness.sv` puts `cadr_axi_master` and `cadr_axi_widen`
// underneath, exactly as `rtl/cadr_arty.sv`'s `g_ddr` does, because the
// question the steps ask is not whether a state machine sequences but whether
// a word ends up at an address --- and there are three modules between the
// two.  Each of the three has a check of its own; this is the only one that
// asks them the question together.
//
// A SEQUENCE IS ONE TRANSACTION OR TWO, and that is the shape of step three.
// A write board writes `word` at `addr` and stops.  A read board reads `addr`
// and then WRITES BACK WHAT CAME BACK, raw, to `echo_addr` --- so that the
// comparing is done by whoever reads `echo_addr` afterwards and not by a lamp
// the fabric lights itself.  Everything below is written per transaction for
// that reason: the expectation moves on when the read completes.
//
// WHAT IT HOLDS THE WITNESS TO.
//
//   THE WRITE LANDS WHERE IT WAS ASKED TO AND NOWHERE ELSE.  The model
//   memory is filled with the COMPLEMENT of the word that should land there
//   before every transaction, so a word that half-landed, a strobe pattern
//   that opened both halves of the beat, or an address that lost a bit all
//   leave something that differs from the answer in every bit.  CLAUDE.md's
//   "a stimulus that poisons cannot move with the bug": against a memory of
//   zeros most of those are indistinguishable from a write that never
//   happened.
//
//   AND THE COMPLEMENT OF THE ECHOED WORD, NOT OF `word`, for the beat the
//   write-back goes into.  In the wrong-half case the witness reads the
//   FILLER and echoes it, so a beat filled with the filler could not tell
//   that write-back from one that never happened --- the
//   memory-whose-only-exercise-writes-one-constant trap, one move along.
//   `vivado/prove_read.tcl` gives the echo beat its own filler for exactly
//   this reason and says so.
//
//   THE BEAT IS COMPARED AGAINST WHAT THE STIMULUS ASKED FOR, not against
//   what the DUT presented.  `awaddr`, `wstrb` and the strobed half of
//   `wdata` are each checked against the address and word the testbench chose,
//   which is the one structure a shadow memory cannot have: a model keyed by
//   the DUT's own address writes consistent nonsense at the wrong beat and
//   reads it back from the same wrong beat.  The write-back's word is the
//   stimulus's too: it is the half of the read beat THIS FILE seeded, so a
//   witness that echoed its own `want` instead of what the memory returned
//   is caught by the wrong-word and wrong-half cases.
//
//   THE WORD IT READ IS STILL THERE AFTERWARDS.  The read's whole beat is
//   required to be exactly as it was seeded once the sequence is over, which
//   is what says the write-back cannot overwrite the thing it read.  On the
//   board that is `PROVE_ECHO` being seven beats from `PROVE_ADDR`; here the
//   addresses sweep and the property is checked at every one of them.
//
//   EXACTLY ONE HANDSHAKE PER CHANNEL PER TRANSACTION.  A master that held
//   `awvalid` up after `awready` issues a second write, and a slave that only
//   recorded the address could not tell.  A write board owes one AW, one W and
//   one B and no AR or R at all; a read board owes one of each of the five,
//   because it is a read and then a write and never three of anything.
//
//   THE 80 ns THE BUS SPECIFICATION PUTS ON A MASTER, ON BOTH TRANSACTIONS.
//   `rtl/cadr_ddr.xdc` relaxes the adapter's address and data registers to
//   sixteen ticks on the strength of it, and on a `PROVE` board this module is
//   the master that owes it.  Nothing else anywhere would notice a witness
//   that raised `mem_req` in the same tick as the address --- the constraint
//   would simply become a claim about a board where it is false.  The
//   write-back is a transaction of its own and owes them again.
//
//   THE PAYLOAD IS WHAT WAS ASKED FOR AND NOT WHAT THE INPUTS SAY BY NOW.
//   Once a sequence is under way the testbench SCRIBBLES over `addr`, `word`,
//   `echo_addr` and `writes` --- with the complement of the word and each
//   address moved into the neighbouring lane, so that a witness reading its
//   inputs instead of its own registers lands in the wrong half and compares
//   against poison.  On the board those four are tied to constants and none of
//   this could ever show; here it is what makes the latching load-bearing, and
//   the latching is what `rtl/cadr_ddr.xdc`'s eighty nanoseconds are a claim
//   about.  `echo_addr` is scribbled at the same instant the payload is taken,
//   which is long before the write-back needs it --- so a witness that read
//   the pin at that moment rather than its own copy writes one lane over.
//
//   ONE SEQUENCE PER RISE OF `go`, AND NOT ONE PER TICK.  Both steps' whole
//   requirement is that it happens once, with nobody at the board, and stops.
//   `go` is tied high on the board, so `HELD` is where the witness stays.
//
//   AND A RESET RUNS IT AGAIN, CLEANLY.  That is the re-arm: on the board,
//   writing `LVL_SHFTR_EN` 0x0 then 0xF drops `SAXIHP0ARESETN` and raises it,
//   which is this `rst` with `go` never falling.  Here the board's three cases
//   are each run, re-poisoned and run a second time through a reset, and the
//   second run is held to everything the first was.  Without it a witness that
//   could only ever fire once would pass, and the board session --- three
//   cases, one programming --- would not exist.
//
//   AND THE VERDICT LAMP CAN STILL SAY NO.  It is no longer the observer, but
//   it costs nothing and somebody at the board can read it, so it is checked:
//   a read of a word that is not the one wanted must clear `matched`, and so
//   must a read of the RIGHT word from the WRONG HALF, and so must SLVERR or
//   DECERR on either transaction of the sequence.

#include <cstdio>
#include <cstdlib>
#include <map>
#include <vector>

#include "Vcadr_prove_harness.h"
#include "verilated.h"

namespace {

int bad = 0;
long tick = 0;
const char *phase = "startup";

void Fail(const char *what, unsigned long long got, unsigned long long want) {
  std::fprintf(stderr, "tick %ld [%s]: %s is 0x%llx, expected 0x%llx\n", tick,
               phase, what, got, want);
  ++bad;
}

void Say(const char *what) {
  std::fprintf(stderr, "tick %ld [%s]: %s\n", tick, phase, what);
  ++bad;
}

unsigned lcg(unsigned &s) {
  s = s * 1664525u + 1013904223u;
  return s >> 8;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Vcadr_prove_harness;

  // The model memory: 64-bit beats, keyed by beat address. Only the slave
  // below ever writes it through the port, and only this file ever seeds it.
  std::map<unsigned, unsigned long long> mem;

  // The slave's own state.
  bool aw_taken = false, w_taken = false, ar_taken = false;
  unsigned aw_addr = 0, ar_addr = 0;
  unsigned long long w_data = 0;
  unsigned w_strb = 0;
  int aw_delay = 0, w_delay = 0, ar_delay = 0, b_wait = -1, r_wait = -1;
  unsigned resp = 0;  // what the slave will answer THIS transaction with

  // Counted per sequence: a second handshake on any channel is a bug.
  int aw_count = 0, w_count = 0, b_count = 0, ar_count = 0, r_count = 0;

  // The stimulus for the sequence in flight.
  unsigned want_addr = 0, want_word = 0, want_echo = 0;
  bool want_write = false, want_match = false;
  // What the write-back must carry: the half of the read's beat that THIS
  // FILE seeded, which is what a correct witness will have read.
  unsigned echo_expect = 0;
  // The read's beat exactly as it was seeded, so that it can be required to
  // be untouched once the sequence is over.
  unsigned long long read_beat_seed = 0;
  // What both halves of the write-back's beat hold before it runs.
  unsigned echo_fill = 0;
  // Which transaction of the sequence, if any, the slave refuses.
  int err_stage = -1;
  unsigned resp_val = 0;
  bool rearm_due = false;

  // The transaction in flight, which is the first of the sequence or the
  // write-back. Everything the slave checks is compared against these.
  unsigned exp_addr = 0, exp_word = 0;
  bool exp_write = false;
  int stage = 0;

  // The sequence's own phase, in ticks of the main loop rather than in a
  // spin of its own: a nested loop that clocked the DUT without the slave
  // running would be a different testbench for those ticks.
  //   0 waiting for the answer
  //   1 answered; `go` still up, and nothing more may go out
  //   2 `go` down, giving the witness edges to see it fall on
  //   3 the port is being reset under a `go` that never falls
  enum { WAITING, HOLDING, COOLING, REARMING };
  int tphase = WAITING;
  int hold_left = 0;
  int rearm_rst_left = 0;
  bool in_flight = false;

  // The 80 ns rule: the tick the request went up, and the tick the address
  // and word last changed.
  long payload_settled = -1;
  unsigned last_addr = 0, last_wdata = 0;
  int last_write = 0;
  long min_setup = 1 << 30;

  long writes_done = 0, reads_done = 0, matches = 0, mismatches = 0;
  long errors_injected = 0, lane_cases = 0, neighbour_cases = 0;
  long echoes_checked = 0, echo_neighbours = 0, read_beats_intact = 0;
  long rearms = 0, repeats_refused = 0;

  unsigned seed = 20260909;

  auto seed_beat = [&](unsigned addr, unsigned lo, unsigned hi) {
    mem[addr & ~7u] = (static_cast<unsigned long long>(hi) << 32) | lo;
  };

  dut->clk = 0;
  dut->rst = 1;
  dut->go = 0;
  dut->addr = 0;
  dut->word = 0;
  dut->echo_addr = 0;
  dut->writes = 0;
  dut->hp0_awready = 0;
  dut->hp0_wready = 0;
  dut->hp0_bvalid = 0;
  dut->hp0_bresp = 0;
  dut->hp0_arready = 0;
  dut->hp0_rvalid = 0;
  dut->hp0_rdata = 0;
  dut->hp0_rresp = 0;
  dut->hp0_rlast = 0;
  dut->eval();

  // The transaction script. Each entry is one rise of `go`.
  //
  // The addresses sweep bit 2 and every bit above the beat boundary, because
  // that is what `cadr_axi_widen.sv` uses to place the strobes and to select
  // the lane, and an address that only ever took one value on either would
  // leave both untested. They are all inside `cadr_ddr_map`'s main-memory
  // region, which is where the board's are.
  //
  // The second address is the first with bits 2, 3 and 4 flipped: a different
  // beat, so the write-back cannot reach what it read, and the other half of
  // it, so a widening stuck on one half is caught in one direction or the
  // other. The board's own pair has the same two properties and its own
  // reasons for the exact numbers, which `rtl/cadr_arty.sv` gives.
  struct Op {
    unsigned addr, word, echo;
    bool write;
    int kind;
    unsigned wrongbit;
    bool rearm;
  };
  // kind: 0 plain
  //       1 the slave refuses the FIRST transaction
  //       2 read a word differing from the one wanted in one bit
  //       3 read the right word from the WRONG HALF of the beat
  //       4 the slave refuses the WRITE-BACK
  std::vector<Op> ops;
  {
    const unsigned base = 0x18000000u;
    for (int i = 0; i < 96; ++i) {
      unsigned a = base + (lcg(seed) & 0x03FFFFFCu);
      unsigned w = lcg(seed) ^ (lcg(seed) << 16);
      if (w == 0 || w == 0xFFFFFFFFu) w = 0x8A5C36E1u;
      int kind = 0;
      if (i % 7 == 3) kind = 1;
      if (!(i & 1)) {
        // Reads: right, one bit wrong, right-word-wrong-half, and a
        // write-back the port refuses.
        if (i % 6 == 0) kind = 2;
        else if (i % 6 == 4) kind = 3;
        else if (i % 10 == 2) kind = 4;
      }
      ops.push_back({a, w, a ^ 0x1Cu, (i & 1) != 0, kind,
                     static_cast<unsigned>(i % 32), false});
    }
    // And the board's own numbers, so the thing that will be built is a case
    // here and not merely a configuration of one. `PROVE=1` writes; the three
    // that follow are the three cases `vivado/prove_read.tcl` runs in one
    // session, in its order, each one re-armed and run again.
    const unsigned A = 0x18A72EE4u, W = 0x8A5C36E1u, E = 0x18A72F18u;
    ops.push_back({A, W, E, true,  0, 0, false});   // step two
    ops.push_back({A, W, E, false, 2, 0, true});    // CASE=wrong, bit 0
    ops.push_back({A, W, E, false, 3, 0, true});    // CASE=half
    ops.push_back({A, W, E, false, 0, 0, true});    // CASE=right
  }

  size_t op = 0;
  int idle = 0;
  const long TICKS = 400000;

  // Lay the memory out for the op about to run, and put its stimulus on the
  // pins. Called once when the op starts and again before each re-arm, so
  // that a second run has exactly the memory the first one found --- which is
  // what the board's script does between cases, and the only way a write-back
  // that happened can be told from one that did not.
  auto arm_op = [&](const Op &o) {
    want_addr = o.addr & ~3u;
    want_echo = o.echo & ~3u;
    want_word = o.word;
    want_write = o.write;
    err_stage = (o.kind == 1) ? 0 : (o.kind == 4 ? 1 : -1);
    resp_val = (op & 1) ? 2u : 3u;  // SLVERR / DECERR

    // POISON, NOT ZERO. The beat this transaction is about is filled with
    // the complement of the word, so nothing the DUT could half-do reads
    // back as the answer.
    unsigned comp = ~want_word;
    bool hi = (want_addr & 4u) != 0;
    unsigned lo_w = comp, hi_w = comp;
    if (!want_write) {
      if (o.kind == 2) {
        (hi ? hi_w : lo_w) = want_word ^ (1u << o.wrongbit);
      } else if (o.kind == 3) {
        // The right word, in the half the address does NOT select.
        (hi ? lo_w : hi_w) = want_word;
      } else {
        (hi ? hi_w : lo_w) = want_word;
      }
    }
    seed_beat(want_addr, lo_w, hi_w);
    read_beat_seed = mem[want_addr & ~7u];
    // What a correct witness will read, and therefore what it must write
    // back. Taken from what THIS FILE put there and never from the DUT.
    echo_expect = hi ? hi_w : lo_w;

    // The write-back's beat gets the complement of the word that should land
    // in it --- of `echo_expect` and not of `want_word`, see the header. A
    // write board has no write-back, so its second address gets the same
    // filler as everything else and is required to still hold it afterwards.
    echo_fill = want_write ? comp : ~echo_expect;
    seed_beat(want_echo, echo_fill, echo_fill);

    want_match = want_write ? (err_stage < 0)
                            : (echo_expect == want_word && err_stage < 0);

    dut->addr = want_addr;
    dut->word = want_word;
    dut->echo_addr = want_echo;
    dut->writes = want_write;

    stage = 0;
    exp_addr = want_addr;
    exp_word = want_word;
    exp_write = want_write;
    resp = (err_stage == 0) ? resp_val : 0u;
    aw_count = w_count = b_count = ar_count = r_count = 0;
    aw_taken = w_taken = ar_taken = false;
    b_wait = r_wait = -1;
    aw_delay = lcg(seed) % 5;
    w_delay = lcg(seed) % 5;
    ar_delay = lcg(seed) % 5;
    tphase = WAITING;
    idle = 0;
  };

  for (tick = 0; tick < TICKS && bad < 20 && op <= ops.size(); ++tick) {
    // Held at the start, and held again for every re-arm: on the board that
    // is LVL_SHFTR_EN going 0x0 and back to 0xF under a `go` tied high.
    if (rearm_rst_left > 0) --rearm_rst_left;
    dut->rst = (tick < 8) || (rearm_rst_left > 0);

    // ---------------------------------------------------------- the slave
    //
    // Ready is offered with a varying delay on each channel independently,
    // and the response after a varying wait, because a master that only ever
    // met one shape of handshake would pass a check that only ever offered
    // one.
    if (!dut->rst) {
      if (dut->hp0_awvalid && !aw_taken) {
        if (aw_delay > 0) { --aw_delay; dut->hp0_awready = 0; }
        else dut->hp0_awready = 1;
      } else dut->hp0_awready = 0;

      if (dut->hp0_wvalid && !w_taken) {
        if (w_delay > 0) { --w_delay; dut->hp0_wready = 0; }
        else dut->hp0_wready = 1;
      } else dut->hp0_wready = 0;

      if (dut->hp0_arvalid && !ar_taken) {
        if (ar_delay > 0) { --ar_delay; dut->hp0_arready = 0; }
        else dut->hp0_arready = 1;
      } else dut->hp0_arready = 0;
    } else {
      dut->hp0_awready = dut->hp0_wready = dut->hp0_arready = 0;
      dut->hp0_bvalid = dut->hp0_rvalid = 0;
    }

    // ------------------------------------------------------- the stimulus
    if (!dut->rst && !in_flight && op < ops.size()) {
      const Op &o = ops[op];
      arm_op(o);
      rearm_due = o.rearm;
      if (err_stage >= 0) ++errors_injected;
      if (o.kind == 3) ++lane_cases;
      dut->go = 1;
      in_flight = true;
    }

    // WHAT THE EDGE SAW, SAMPLED BEFORE IT. `eval()` at the rising edge
    // updates the registers AND recomputes everything combinational from
    // them, so a `valid` read afterwards is the NEXT cycle's and the
    // handshake that just happened is gone. Every handshake here is detected
    // from this snapshot; the DUT's own registered outputs are read after the
    // edge, where they are the value the edge produced.
    dut->eval();
    const int s_awvalid = dut->hp0_awvalid, s_awready = dut->hp0_awready;
    const int s_wvalid = dut->hp0_wvalid, s_wready = dut->hp0_wready;
    const int s_arvalid = dut->hp0_arvalid, s_arready = dut->hp0_arready;
    const int s_bvalid = dut->hp0_bvalid, s_bready = dut->hp0_bready;
    const int s_rvalid = dut->hp0_rvalid, s_rready = dut->hp0_rready;
    const unsigned s_awaddr = dut->hp0_awaddr, s_araddr = dut->hp0_araddr;
    const unsigned long long s_wdata = dut->hp0_wdata;
    const unsigned s_wstrb = dut->hp0_wstrb;

    dut->clk = 1;
    dut->eval();

    // ------------------------------------------------- what the edge did
    if (!dut->rst) {
      // The 80 ns rule. The payload is the address, the word and the
      // direction; the request may not go up until sixteen ticks after the
      // last of them settled. The write-back moves all three and owes the
      // same sixteen, which is why this is not reset per sequence.
      if (dut->mem_addr != last_addr || dut->mem_wdata != last_wdata ||
          dut->mem_write != last_write) {
        last_addr = dut->mem_addr;
        last_wdata = dut->mem_wdata;
        last_write = dut->mem_write;
        payload_settled = tick;
      }

      if (s_awvalid && s_awready) {
        ++aw_count;
        aw_taken = true;
        aw_addr = s_awaddr;
      }
      if (s_wvalid && s_wready) {
        ++w_count;
        w_taken = true;
        w_data = s_wdata;
        w_strb = s_wstrb;
      }
      if (s_arvalid && s_arready) {
        ++ar_count;
        ar_taken = true;
        ar_addr = s_araddr;
      }

      // The write commits when both halves of it have been taken.
      if (aw_taken && w_taken && b_wait < 0) {
        // THE BEAT IS CHECKED AGAINST THE STIMULUS AND NOT AGAINST THE DUT.
        // On the write-back `exp_addr` is the second address the stimulus
        // gave and `exp_word` the half of the read beat this file seeded.
        unsigned want_beat = exp_addr & ~7u;
        if (aw_addr != want_beat) Fail("awaddr", aw_addr, want_beat);
        unsigned want_strb = (exp_addr & 4u) ? 0xF0u : 0x0Fu;
        if (w_strb != want_strb) Fail("wstrb", w_strb, want_strb);
        unsigned half = (exp_addr & 4u)
                            ? static_cast<unsigned>(w_data >> 32)
                            : static_cast<unsigned>(w_data);
        if (half != exp_word) Fail("the strobed half of wdata", half,
                                   exp_word);
        // Apply it the way a slave would: byte by byte, under the strobes.
        // A strobe pattern that opened both halves therefore destroys the
        // neighbour here exactly as it would on the board.
        unsigned long long cur = mem[want_beat];
        unsigned long long nw = cur;
        for (int b = 0; b < 8; ++b) {
          if (w_strb & (1u << b)) {
            unsigned long long m = 0xFFULL << (8 * b);
            nw = (nw & ~m) | (w_data & m);
          }
        }
        if (resp == 0) mem[want_beat] = nw;
        b_wait = 1 + static_cast<int>(lcg(seed) % 4);
      }
      if (b_wait > 0) --b_wait;
      if (b_wait == 0 && !dut->hp0_bvalid) {
        dut->hp0_bvalid = 1;
        dut->hp0_bresp = resp;
      }
      if (s_bvalid && s_bready) {
        ++b_count;
        dut->hp0_bvalid = 0;
        b_wait = -1;
        // ANSWERED, so the transaction is over as far as this channel is
        // concerned. Without this the slave issues a SECOND response the next
        // tick --- the condition above is still true --- and the adapter picks
        // it up at the start of the NEXT transaction, which reads as an error
        // one transaction late. It cost an hour.
        aw_taken = w_taken = false;
      }

      if (ar_taken && r_wait < 0) {
        unsigned want_beat = exp_addr & ~7u;
        if (ar_addr != want_beat) Fail("araddr", ar_addr, want_beat);
        r_wait = 1 + static_cast<int>(lcg(seed) % 4);
      }
      if (r_wait > 0) --r_wait;
      if (r_wait == 0 && !dut->hp0_rvalid) {
        dut->hp0_rvalid = 1;
        dut->hp0_rdata = mem[exp_addr & ~7u];
        dut->hp0_rresp = resp;
        dut->hp0_rlast = 1;
      }
      if (s_rvalid && s_rready) {
        ++r_count;
        dut->hp0_rvalid = 0;
        r_wait = -1;
        ar_taken = false;   // see the B channel above
        // THE READ IS OVER AND THE WRITE-BACK IS NEXT. The expectation moves
        // to the second address and to the word the stimulus put in the half
        // the read selected; the slave from here on is holding the witness to
        // sending that word out again, unaltered.
        if (in_flight && stage == 0 && !want_write) {
          stage = 1;
          exp_addr = want_echo;
          exp_word = echo_expect;
          exp_write = true;
          resp = (err_stage == 1) ? resp_val : 0u;
          aw_delay = lcg(seed) % 5;
          w_delay = lcg(seed) % 5;
        }
      }

      // The request going up: check the setup it was given.
      static int p_req = 0;
      if (dut->mem_req && !p_req) {
        long setup = tick - payload_settled;
        if (setup < min_setup) min_setup = setup;
        if (setup < 16) {
          std::fprintf(stderr,
                       "tick %ld: mem_req rose %ld ticks after the payload "
                       "settled; the bus gives the master 80 ns and "
                       "rtl/cadr_ddr.xdc relaxes the adapter on it\n",
                       tick, setup);
          ++bad;
        }
      }
      p_req = dut->mem_req;
    }

    dut->clk = 0;
    dut->eval();

    // THE INPUTS GO BAD ONCE THE PAYLOAD IS TAKEN. See the header: a witness
    // that read these instead of its own registers would address the
    // neighbouring lane and compare against the complement of the word.
    if (in_flight && tphase == WAITING && dut->mem_addr == want_addr) {
      dut->addr = want_addr ^ 4u;
      dut->word = ~want_word;
      dut->echo_addr = want_echo ^ 4u;
      dut->writes = !want_write;
    }

    // ------------------------------------------------------ the verdict
    if (in_flight && tphase == HOLDING) {
      // ONE SEQUENCE PER RISE. `go` is still up and nothing more may go
      // out; both steps' whole requirement is that it happens once.
      if (dut->mem_req) {
        Say("a second sequence while `go` was held");
        tphase = COOLING;
        hold_left = 4;
        dut->go = 0;
      } else if (--hold_left <= 0) {
        ++repeats_refused;
        dut->go = 0;
        tphase = COOLING;
        hold_left = 4;
      }
    } else if (in_flight && tphase == COOLING) {
      if (--hold_left <= 0) {
        in_flight = false;
        ++op;
        idle = 0;
      }
    } else if (in_flight && tphase == REARMING) {
      // The port is down. `go` never falls, the stimulus is back on the pins
      // and the memory is laid out again; when the reset lifts the whole
      // sequence must run a second time and be right a second time.
      if (rearm_rst_left == 0) {
        if (dut->has_run) Say("`has_run` survived the port being reset");
        tphase = WAITING;
        idle = 0;
      }
    } else if (in_flight && dut->has_run) {
      phase = want_write ? "write" : "read";
      if (want_write) {
        ++writes_done;
        if (aw_count != 1) Fail("AW handshakes", aw_count, 1);
        if (w_count != 1) Fail("W handshakes", w_count, 1);
        if (b_count != 1) Fail("B handshakes", b_count, 1);
        if (ar_count != 0) Fail("AR handshakes on a write", ar_count, 0);
        if (r_count != 0) Fail("R handshakes on a write", r_count, 0);
        // And the memory itself: the word where it was asked for, the
        // complement everywhere else in the beat.
        if (resp == 0) {
          unsigned long long beat = mem[want_addr & ~7u];
          unsigned lo = static_cast<unsigned>(beat);
          unsigned hi = static_cast<unsigned>(beat >> 32);
          unsigned got = (want_addr & 4u) ? hi : lo;
          unsigned nbr = (want_addr & 4u) ? lo : hi;
          if (got != want_word) Fail("the word in memory", got, want_word);
          if (nbr != (~want_word & 0xFFFFFFFFu)) {
            Fail("the neighbour in the beat", nbr, ~want_word & 0xFFFFFFFFu);
          }
          ++neighbour_cases;
        }
        // A WRITE BOARD NEVER TOUCHES THE SECOND ADDRESS. Its beat was laid
        // out like a read board's and must be exactly as it was left: this is
        // what says a write board owes one transaction and not two.
        unsigned long long ebeat = mem[want_echo & ~7u];
        unsigned long long efill =
            (static_cast<unsigned long long>(echo_fill) << 32) | echo_fill;
        if (ebeat != efill) {
          Fail("the second address's beat after a write", ebeat, efill);
        }
      } else {
        ++reads_done;
        if (ar_count != 1) Fail("AR handshakes", ar_count, 1);
        if (r_count != 1) Fail("R handshakes", r_count, 1);
        if (aw_count != 1) Fail("AW handshakes for the write-back", aw_count, 1);
        if (w_count != 1) Fail("W handshakes for the write-back", w_count, 1);
        if (b_count != 1) Fail("B handshakes for the write-back", b_count, 1);

        // WHAT THE OBSERVER OUTSIDE WOULD READ. The word that came back,
        // written out raw at the second address --- and the second address's
        // neighbour, which a strobe pattern opening both halves destroys.
        if (err_stage != 1) {
          unsigned long long ebeat = mem[want_echo & ~7u];
          unsigned elo = static_cast<unsigned>(ebeat);
          unsigned ehi = static_cast<unsigned>(ebeat >> 32);
          unsigned egot = (want_echo & 4u) ? ehi : elo;
          unsigned enbr = (want_echo & 4u) ? elo : ehi;
          if (egot != echo_expect) {
            Fail("the word written back", egot, echo_expect);
          }
          ++echoes_checked;
          if (enbr != echo_fill) {
            Fail("the neighbour of the second address", enbr, echo_fill);
          }
          ++echo_neighbours;
        }

        // AND THE WORD IT READ IS STILL THERE. The write-back must not be
        // able to reach the beat it came out of.
        unsigned long long rbeat = mem[want_addr & ~7u];
        if (rbeat != read_beat_seed) {
          Fail("the beat the read came out of", rbeat, read_beat_seed);
        }
        ++read_beats_intact;
      }
      if (dut->matched != (want_match ? 1 : 0)) {
        Fail("matched", dut->matched, want_match ? 1 : 0);
      }
      if (dut->matched) ++matches; else ++mismatches;
      phase = "between";
      if (rearm_due) {
        // THE RE-ARM. `go` stays up --- it is tied high on the board --- the
        // memory goes back to what this op started with, and the port is
        // reset for a few ticks. That is LVL_SHFTR_EN 0x0 then 0xF.
        rearm_due = false;
        arm_op(ops[op]);
        ++rearms;
        rearm_rst_left = 6;
        tphase = REARMING;
      } else {
        tphase = HOLDING;
        hold_left = 24;
      }
      idle = 0;
    }

    if (in_flight && ++idle > 4000) {
      Say("the witness never finished a sequence");
      break;
    }
  }

  // What was reached. A count that came out zero means the case was written
  // and never ran, which is the failure a green run hides.
  std::printf("prove: %ld writes, %ld reads, %ld matched, %ld did not\n",
              writes_done, reads_done, matches, mismatches);
  std::printf("prove: %ld errors injected, %ld wrong-half reads, "
              "%ld neighbours checked\n",
              errors_injected, lane_cases, neighbour_cases);
  std::printf("prove: %ld words written back and compared, %ld of their "
              "neighbours checked\n", echoes_checked, echo_neighbours);
  std::printf("prove: %ld reads left the beat they came out of untouched\n",
              read_beats_intact);
  std::printf("prove: %ld sequences re-armed by a reset under a held `go`\n",
              rearms);
  std::printf("prove: %ld sequences refused a repeat while `go` was held\n",
              repeats_refused);
  std::printf("prove: the request never rose sooner than %ld ticks after the "
              "payload settled (the bus asks 16)\n", min_setup);

  if (op != ops.size()) {
    std::fprintf(stderr, "prove: only %zu of %zu sequences ran\n", op,
                 ops.size());
    ++bad;
  }
  if (writes_done == 0 || reads_done == 0 || matches == 0 ||
      mismatches == 0 || errors_injected == 0 || lane_cases == 0 ||
      echoes_checked == 0 || echo_neighbours == 0 ||
      read_beats_intact == 0 || rearms == 0) {
    std::fprintf(stderr, "prove: a case was written and never ran\n");
    ++bad;
  }
  if (bad) {
    std::fprintf(stderr, "prove: FAILED, %d disagreement(s)\n", bad);
    return 1;
  }
  std::printf("prove: ok\n");
  delete dut;
  return 0;
}
