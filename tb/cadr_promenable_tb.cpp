// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `-PROMENABLE` on the whole machine: the net the blue lamp shows.
//
// The DUT is `rtl/machine/cadr_machine.sv` with MIT's boot PROM in it, in the
// shape `tb/cadr_no_auto_boot_tb.cpp` and `tb/cadr_kbd_boot_tb.cpp` use --- no
// memory modelled, because the PROM's first main-memory cycle is at microcycle
// 536,303 and nothing here gets near it.
//
// **WHY THIS CHECK EXISTS.**  The three boards drive their blue lamp from
// `promenable`, which is MIT's `-PROMENABLE` at PCTL 1C19 and NOT the mode
// register's `PROMDISABLE` bit.  The two agree almost everywhere, which is
// exactly the trap: a board wired to the mode bit instead would look right to
// anybody watching, and no check in this tree looked at either.  A board's top
// level is reached by lint and by nothing else, so what can be held here is the
// net as `cadr_machine` presents it at its port.
//
// `promenable` is `BOTTOM.1K AND -PROMDISABLED AND -IWRITEDA AND -IDEBUG`.
// With no debugger on the machine that is three terms, and all three are
// exercised by the boot PROM itself:
//
//   1. **IT IS UP ON A FETCH AND DOWN ON A CONTROL-STORE WRITE.**  The PROM's
//      first act is to clear all 16,384 words of the control store, and
//      `IWRITED` is up for the microcycle each write lands in.  So the lamp is
//      blue and a little under full brightness while the store loads, and the
//      dimming is the write pass.  A fabric driving the lamp from the mode bit
//      is caught here: `!promdisable` is up on those cycles and `promenable`
//      is not.
//   2. **IT IS DARK ONCE `PROMDISABLE` IS SET, AND THE PC IS NOT WHAT MAKES
//      IT SO.**  The mode register is written over the console's own Unibus
//      port, as `cadr_kbd_boot_tb.cpp` writes it, and the machine then runs
//      out of the control store the PROM cleared --- so its PC walks the
//      bottom 1k again, which is where `BOTTOM.1K` is true and the lamp would
//      light if that term were all there were.  It must stay dark.
//   3. **AND THE TERMS ARE ASSERTED TOGETHER, EVERY TICK**, rather than one
//      case at a time: the identity `promenable == bottom_1k && !iwrited` is
//      checked on every tick of the first phase, and `promenable == 0` on
//      every tick of the second.  Neither is a window that happened to catch
//      the right instant.
//
// Non-vacuity is asserted rather than assumed.  The first phase counts the
// ticks in each of the two states and fails if either is empty; the second
// counts the ticks that WOULD have lit the lamp under `BOTTOM.1K` alone and
// fails if there are none.
//
// Build and run:
//     verilator --cc --exe --build -Wall -Wno-fatal \
//         -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
//         -Mdir build/obj_promenable \
//         -GPROM_HEX='"'"$PWD"'/build/boot_prom.hex"' \
//         --top-module cadr_machine <the machine's sources> \
//         "$PWD"/tb/cadr_promenable_tb.cpp
//     build/obj_promenable/Vcadr_machine

#include <cstdio>
#include <cstdlib>
#include "Vcadr_machine.h"
#include "verilated.h"

namespace {

// The boot PROM is 1,024 words --- `PROM_WORDS` in `cadr_microcycle.sv` --- and
// `BOTTOM.1K` is `PC < PROM_WORDS`.
constexpr unsigned kPromWords = 1024;

// How long the PROM is watched before `PROMDISABLE` is set.  Control-store
// writes have to be INSIDE the window or claim 1 is a claim about one state
// only, and the check below fails by name if there are none --- so the figure
// is measured rather than guessed.  Measured: the PROM's first `IWRITED`
// microcycle is at tick 18,076,926, and by 19,500,000 the window holds 203,324
// `IWRITED` ticks, which is 4,621 words written at 44 ticks apiece, the
// microcycle at extra slow.  The whole pass is 16,384 words and runs on well
// past this; it is not waited out, because a few thousand writes say what all
// of them say and the run already takes about fifteen seconds.
constexpr long kRunT = 19500000;

// How long the machine is watched with `PROMDISABLE` set.  It is executing the
// cleared control store by then, so a few hundred thousand ticks is thousands
// of microcycles of a PC walking the bottom 1k.
constexpr long kDarkT = 400000;

// Eight ticks of reset, as every check here holds it.
constexpr long kResetT = 8;

int bad = 0;

void Fail(const char *what, long got, long want) {
  std::fprintf(stderr, "FAIL: %s is %ld, wanted %ld\n", what, got, want);
  ++bad;
}

struct Mach {
  Vcadr_machine *d;
  long tick = 0, micro = 0;

  Mach() : d(new Vcadr_machine) {
    d->clk = 0;
    d->rst = 1;
    d->no_auto_boot = 0;
    d->boards = 32;
    d->device_ack = 0;
    d->device_rdata = 0;
    d->mem_done = 0;
    d->mem_rdata = 0;
    d->n_boot2 = 1;
    d->kbd_strobe = 0;
    d->kbd_code = 0;
    d->mouse_lines = 0x7F;
    d->ser_tx_take = 0;
    d->ser_tx_done = 0;
    d->ser_rx_strobe = 0;
    d->ser_rx_data = 0;
    d->ser_rx_end = 0;
    d->ser_rx_parity = 0;
    d->ser_rx_framing = 0;
    d->ser_plugged = 0;
    d->chaos_address = 0;
    d->chaos_rx_valid = 0;
    d->chaos_rx_word = 0;
    d->chaos_rx_done = 0;
    d->chaos_rx_bits = 0;
    d->chaos_rx_crc = 0;
    d->chaos_tx_done = 0;
    d->chaos_tx_abort = 0;
    d->chaos_cbl_busy = 0;
    d->drive_present = 0;
    d->drive_read_only = 0;
    d->store_deny = 0;
    d->store_rdata = 0;
    d->con_req = 0;
    d->con_msyn = 0;
    d->con_write = 0;
    d->con_addr = 0;
    d->con_wdata = 0;
    d->dbg_in_req = 0;
    d->dbg_in_wr = 0;
    d->dbg_in_a = 0;
    d->dbd_in = 0;
    d->debuggee_reset = 0;
    d->timeout_inhibit = 0;
    d->dbg_rst = 0;
    d->eval();
  }
  ~Mach() { d->final(); delete d; }

  void Step(long n) {
    for (long k = 0; k < n; ++k) {
      d->rst = (tick < kResetT);
      d->clk = 1;
      d->eval();
      if (d->clock_edge) ++micro;
      d->clk = 0;
      d->eval();
      ++tick;
    }
  }

  // `cadr_spy_registers.sv` is the slave at `0o766000` and the mode register is
  // EADR 5, the registers two bytes apart, so `0o766012`; bit 5 is
  // `PROMDISABLE`.  The handshake is the Unibus's own and is bounded at every
  // wait, so a fabric that never grants or never answers fails here rather
  // than hanging.  Taken from `tb/cadr_kbd_boot_tb.cpp`, which writes the same
  // register for the neighbouring reason.
  bool UnibusWrite(unsigned addr, unsigned word) {
    long k = 0;
    d->con_req = 1;
    while (!d->con_gnt && k++ < 4000) Step(1);
    if (!d->con_gnt) return false;
    d->con_addr = addr;
    d->con_wdata = word;
    d->con_write = 1;
    d->con_msyn = 1;
    k = 0;
    while (!d->con_ssyn && k++ < 4000) Step(1);
    const bool answered = d->con_ssyn != 0;
    d->con_msyn = 0;
    k = 0;
    while (d->con_ssyn && k++ < 4000) Step(1);
    d->con_write = 0;
    d->con_req = 0;
    Step(4);
    return answered;
  }
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  Mach m;
  m.Step(kResetT + 2);

  // --- 1.  THE PROM RUNNING: up on a fetch, down on a control-store write.
  //
  // The identity is asserted on every tick rather than sampled, and the two
  // states are counted so that neither can be empty.  `first_write` is
  // reported because the constant above rests on it.
  long lit = 0, dark_write = 0, wrong = 0, first_write = -1;
  for (long k = 0; k < kRunT; ++k) {
    m.Step(1);
    const bool bottom = m.d->pc < kPromWords;
    const bool iwrited = m.d->iwrited != 0;
    const bool want = bottom && !iwrited;
    if ((m.d->promenable != 0) != want) {
      if (wrong++ == 0)
        std::fprintf(stderr,
                     "FAIL: at tick %ld PROMENABLE is %d with PC %o and "
                     "IWRITED %d, wanted %d\n",
                     m.tick, m.d->promenable, m.d->pc, m.d->iwrited, want);
    }
    if (m.d->promenable) ++lit;
    if (iwrited) {
      ++dark_write;
      if (first_write < 0) first_write = m.tick;
    }
  }
  if (wrong) {
    std::fprintf(stderr, "FAIL: PROMENABLE disagreed on %ld of %ld ticks\n",
                 wrong, kRunT);
    ++bad;
  }
  if (m.d->promdisable) Fail("PROMDISABLE while the PROM runs", m.d->promdisable, 0);
  if (lit == 0) {
    std::fprintf(stderr, "FAIL: PROMENABLE was never up over %ld ticks\n", kRunT);
    ++bad;
  }
  // The control-store pass must be inside the window, or claim 1 is a claim
  // about one state only and the mutation it exists to catch survives.
  if (dark_write == 0) {
    std::fprintf(stderr,
                 "FAIL: no control-store write in %ld ticks, so the lamp was "
                 "never seen to go out\n", kRunT);
    ++bad;
  }
  std::printf("the PROM running: PROMENABLE up on %ld of %ld ticks, "
              "down on %ld IWRITED ticks, the first at %ld\n",
              lit, kRunT, dark_write, first_write);

  // --- 2.  PROMDISABLE SET: dark for good, and the PC is walking the bottom
  //         1k while it is.
  if (!m.UnibusWrite(0766012, 040)) Fail("the mode-register write was answered", 0, 1);
  m.Step(3 * 44);
  if (!m.d->promdisable) Fail("PROMDISABLE after the write", m.d->promdisable, 1);

  long would_light = 0, lit_after = 0;
  const long micro_before = m.micro;
  for (long k = 0; k < kDarkT; ++k) {
    m.Step(1);
    if (m.d->promenable) ++lit_after;
    if (m.d->pc < kPromWords && !m.d->iwrited) ++would_light;
  }
  if (lit_after)
    Fail("PROMENABLE ticks with PROMDISABLE set", lit_after, 0);
  // Without this the case above passes on a machine that has wandered out of
  // the bottom 1k, where `BOTTOM.1K` alone would have held the lamp dark.
  if (would_light == 0) {
    std::fprintf(stderr,
                 "FAIL: the PC never reached the bottom 1k with PROMDISABLE "
                 "set, so nothing was asked of the PROMDISABLED term\n");
    ++bad;
  }
  std::printf("PROMDISABLE set: PROMENABLE up on %ld of %ld ticks, "
              "%ld of them in the bottom 1k with no write, "
              "%ld microcycles retired\n",
              lit_after, kDarkT, would_light, m.micro - micro_before);

  if (bad) {
    std::fprintf(stderr, "FAILED: %d\n", bad);
    return 1;
  }
  std::printf("PROMENABLE: the PROM's own select, on the machine's port\n");
  return 0;
}
