// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The witness, against an AXI3 slave that is not the design.
//
// `rtl/cadr_prove.sv` is the fabric half of the two steps that decide whether
// the memory port works before the machine is put behind it.  On the board its
// other half is a debugger reading DDR --- an observer outside the design, and
// the whole reason those steps are worth doing.  Here that observer is this
// file: a 64-bit AXI3 slave with a model memory the DUT never touches except
// through the port, so a witness that is wrong about the address, the word,
// the lane or the strobes cannot agree with it.
//
// IT IS THE HARNESS AND NOT THE MODULE THAT IS INSTANTIATED, deliberately.
// `tb/cadr_prove_harness.sv` puts `cadr_axi_master` and `cadr_axi_widen`
// underneath, exactly as `rtl/cadr_arty.sv`'s `g_ddr` does, because the
// question step two asks is not whether a state machine sequences but whether
// a word ends up at an address --- and there are three modules between the
// two.  Each of the three has a check of its own; this is the only one that
// asks them the question together.
//
// WHAT IT HOLDS THE WITNESS TO.
//
//   THE WRITE LANDS WHERE IT WAS ASKED TO AND NOWHERE ELSE.  The model
//   memory is filled with the COMPLEMENT of the word before every
//   transaction, so a word that half-landed, a strobe pattern that opened
//   both halves of the beat, or an address that lost a bit all leave
//   something that differs from the answer in every bit.  CLAUDE.md's "a
//   stimulus that poisons cannot move with the bug": against a memory of
//   zeros most of those are indistinguishable from a write that never
//   happened.
//
//   THE BEAT IS COMPARED AGAINST WHAT THE STIMULUS ASKED FOR, not against
//   what the DUT presented.  `awaddr`, `wstrb` and the strobed half of
//   `wdata` are each checked against the address and word the testbench chose,
//   which is the one structure a shadow memory cannot have: a model keyed by
//   the DUT's own address writes consistent nonsense at the wrong beat and
//   reads it back from the same wrong beat.
//
//   EXACTLY ONE HANDSHAKE PER CHANNEL PER TRANSACTION.  A master that held
//   `awvalid` up after `awready` issues a second write, and a slave that only
//   recorded the address could not tell.  `cadr_axi_master`'s own check makes
//   the same demand; it is repeated here because this harness is the one that
//   would notice a witness re-issuing a transaction the adapter had finished.
//
//   THE 80 ns THE BUS SPECIFICATION PUTS ON A MASTER.  `rtl/cadr_ddr.xdc`
//   relaxes the adapter's address and data registers to sixteen ticks on the
//   strength of it, and on a `PROVE` board this module is the master that owes
//   it.  Nothing else anywhere would notice a witness that raised `mem_req` in
//   the same tick as the address --- the constraint would simply become a
//   claim about a board where it is false.
//
//   THE PAYLOAD IS WHAT WAS ASKED FOR AND NOT WHAT THE INPUTS SAY BY NOW.
//   Once a transaction is under way the testbench SCRIBBLES over `addr`,
//   `word` and `writes` --- with the complement of the word and an address
//   four bytes on, so that a witness reading its inputs instead of its own
//   registers lands in the neighbouring lane and compares against poison.  On
//   the board those three are tied to constants and none of this could ever
//   show; here it is what makes the latching load-bearing, and the latching is
//   what `rtl/cadr_ddr.xdc`'s eighty nanoseconds are a claim about.
//
//   ONE TRANSACTION PER RISE OF `go`, AND NOT ONE PER TICK.  Step two's whole
//   requirement is that it happens once, with nobody at the board, and stops;
//   step three's is that a button runs it again.  Both are `go` held or
//   pulsed, and both are checked.
//
//   AND THE VERDICT LAMP CAN SAY NO.  A read of a word that is not the one
//   wanted must clear `matched`, and so must a read of the RIGHT word from
//   the WRONG HALF of the beat --- which is the case a testbench that filled
//   the whole beat with one value would call a pass.  So the neighbour is
//   given the wanted word and the address the complement, and `matched` must
//   still be low.

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
  unsigned resp = 0;  // what the slave will answer this transaction with

  // Counted per transaction: a second handshake on any channel is a bug.
  int aw_count = 0, w_count = 0, b_count = 0, ar_count = 0, r_count = 0;

  // The stimulus for the transaction in flight.
  unsigned want_addr = 0, want_word = 0;
  bool want_write = false, want_err = false, want_match = false;
  // The transaction's own phase, in ticks of the main loop rather than in a
  // spin of its own: a nested loop that clocked the DUT without the slave
  // running would be a different testbench for those ticks.
  //   0 waiting for the answer
  //   1 answered; `go` still up, and nothing more may go out
  //   2 `go` down, giving the witness edges to see it fall on
  enum { WAITING, HOLDING, COOLING };
  int tphase = WAITING;
  int hold_left = 0;
  bool in_flight = false;

  // The 80 ns rule: the tick the request went up, and the tick the address
  // and word last changed.
  long payload_settled = -1;
  unsigned last_addr = 0, last_wdata = 0;
  int last_write = 0;
  long min_setup = 1 << 30;

  long writes_done = 0, reads_done = 0, matches = 0, mismatches = 0;
  long errors_injected = 0, lane_cases = 0, neighbour_cases = 0;
  long repeats_refused = 0;

  unsigned seed = 20260909;

  auto seed_beat = [&](unsigned addr, unsigned lo, unsigned hi) {
    mem[addr & ~7u] = (static_cast<unsigned long long>(hi) << 32) | lo;
  };

  dut->clk = 0;
  dut->rst = 1;
  dut->go = 0;
  dut->addr = 0;
  dut->word = 0;
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

  // The transaction script. Each entry is one press of `go`.
  //
  // The addresses sweep bit 2 and every bit above the beat boundary, because
  // that is what `cadr_axi_widen.sv` uses to place the strobes and to select
  // the lane, and an address that only ever took one value on either would
  // leave both untested. They are all inside `cadr_ddr_map`'s main-memory
  // region, which is where the board's are.
  struct Op { unsigned addr, word; bool write; int kind; };
  // kind: 0 plain, 1 inject an error, 2 read a wrong word,
  //       3 read the right word from the WRONG HALF of the beat
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
        // Reads: alternate right, wrong, and right-word-wrong-half.
        if (i % 6 == 0) kind = 2;
        else if (i % 6 == 4) kind = 3;
      }
      ops.push_back({a, w, (i & 1) != 0, kind});
    }
    // And the board's own numbers, both ways round, so the thing that will be
    // built is a case here and not merely a configuration of one.
    ops.push_back({0x18A72EE4u, 0x8A5C36E1u, true, 0});
    ops.push_back({0x18A72EE4u, 0x8A5C36E1u, false, 0});
    ops.push_back({0x18A72EE4u, 0x8A5C36E1u, false, 2});
  }

  size_t op = 0;
  int idle = 0;
  const long TICKS = 400000;

  for (tick = 0; tick < TICKS && bad < 20 && op <= ops.size(); ++tick) {
    dut->rst = (tick < 8);

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
      want_addr = o.addr & ~3u;
      want_word = o.word;
      want_write = o.write;
      want_err = (o.kind == 1);

      // POISON, NOT ZERO. The beat this transaction is about is filled with
      // the complement of the word, so nothing the DUT could half-do reads
      // back as the answer.
      unsigned comp = ~want_word;
      seed_beat(want_addr, comp, comp);
      if (!want_write) {
        // A read is set up to have a definite right answer, a definite wrong
        // one, or the right answer in the wrong half.
        bool hi = (want_addr & 4u) != 0;
        unsigned lo_w = comp, hi_w = comp;
        if (o.kind == 0 || o.kind == 1) {
          (hi ? hi_w : lo_w) = want_word;
          want_match = (o.kind == 0);
        } else if (o.kind == 2) {
          (hi ? hi_w : lo_w) = want_word ^ 0x00010000u;
          want_match = false;
        } else {
          // The right word, in the half the address does NOT select.
          (hi ? lo_w : hi_w) = want_word;
          want_match = false;
          ++lane_cases;
        }
        seed_beat(want_addr, lo_w, hi_w);
      } else {
        want_match = !want_err;
      }
      if (want_err) ++errors_injected;

      dut->addr = want_addr;
      dut->word = want_word;
      dut->writes = want_write;
      dut->go = 1;
      in_flight = true;
      tphase = WAITING;
      aw_count = w_count = b_count = ar_count = r_count = 0;
      aw_taken = w_taken = ar_taken = false;
      b_wait = r_wait = -1;
      resp = want_err ? ((op & 1) ? 2u : 3u) : 0u;  // SLVERR / DECERR
      aw_delay = lcg(seed) % 5;
      w_delay = lcg(seed) % 5;
      ar_delay = lcg(seed) % 5;
      idle = 0;
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
      // last of them settled.
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
        unsigned want_beat = want_addr & ~7u;
        if (aw_addr != want_beat) Fail("awaddr", aw_addr, want_beat);
        unsigned want_strb = (want_addr & 4u) ? 0xF0u : 0x0Fu;
        if (w_strb != want_strb) Fail("wstrb", w_strb, want_strb);
        unsigned half = (want_addr & 4u)
                            ? static_cast<unsigned>(w_data >> 32)
                            : static_cast<unsigned>(w_data);
        if (half != want_word) Fail("the strobed half of wdata", half,
                                    want_word);
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
        unsigned want_beat = want_addr & ~7u;
        if (ar_addr != want_beat) Fail("araddr", ar_addr, want_beat);
        r_wait = 1 + static_cast<int>(lcg(seed) % 4);
      }
      if (r_wait > 0) --r_wait;
      if (r_wait == 0 && !dut->hp0_rvalid) {
        dut->hp0_rvalid = 1;
        dut->hp0_rdata = mem[want_addr & ~7u];
        dut->hp0_rresp = resp;
        dut->hp0_rlast = 1;
      }
      if (s_rvalid && s_rready) {
        ++r_count;
        dut->hp0_rvalid = 0;
        r_wait = -1;
        ar_taken = false;   // see the B channel above
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
    if (in_flight && dut->mem_addr == want_addr) {
      dut->addr = want_addr ^ 4u;
      dut->word = ~want_word;
      dut->writes = !want_write;
    }

    // ------------------------------------------------------ the verdict
    if (in_flight && tphase == HOLDING) {
      // ONE TRANSACTION PER RISE. `go` is still up and nothing more may go
      // out; step two's whole requirement is that the write happens once.
      if (dut->mem_req) {
        Say("a second transaction while `go` was held");
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
    } else if (in_flight && dut->has_run) {
      phase = want_write ? "write" : "read";
      if (want_write) {
        ++writes_done;
        if (aw_count != 1) Fail("AW handshakes", aw_count, 1);
        if (w_count != 1) Fail("W handshakes", w_count, 1);
        if (b_count != 1) Fail("B handshakes", b_count, 1);
        if (ar_count != 0) Fail("AR handshakes on a write", ar_count, 0);
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
      } else {
        ++reads_done;
        if (ar_count != 1) Fail("AR handshakes", ar_count, 1);
        if (r_count != 1) Fail("R handshakes", r_count, 1);
        if (aw_count != 0) Fail("AW handshakes on a read", aw_count, 0);
        if (w_count != 0) Fail("W handshakes on a read", w_count, 0);
      }
      if (dut->matched != (want_match ? 1 : 0)) {
        Fail("matched", dut->matched, want_match ? 1 : 0);
      }
      if (dut->matched) ++matches; else ++mismatches;
      phase = "between";
      tphase = HOLDING;
      hold_left = 24;
      idle = 0;
    }

    if (in_flight && ++idle > 4000) {
      Say("the witness never finished a transaction");
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
  std::printf("prove: %ld transactions refused a repeat while `go` was held\n",
              repeats_refused);
  std::printf("prove: the request never rose sooner than %ld ticks after the "
              "payload settled (the bus asks 16)\n", min_setup);

  if (op != ops.size()) {
    std::fprintf(stderr, "prove: only %zu of %zu transactions ran\n", op,
                 ops.size());
    ++bad;
  }
  if (writes_done == 0 || reads_done == 0 || matches == 0 ||
      mismatches == 0 || errors_injected == 0 || lane_cases == 0) {
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
