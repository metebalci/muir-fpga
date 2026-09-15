// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The no-auto-boot switch, on the whole machine: a CADR that comes up with its
// boot button unpressed, and the button that starts it.
//
// The DUT is `rtl/machine/cadr_machine.sv` --- the processor, the memory path,
// the bus interface and the I/O board under one roof --- with MIT's boot PROM
// in it.  `build/kbd_boot.pass` is the neighboring check and holds the three
// boot lines; this one holds the state the machine COMES UP in, which is the
// other half of the same page: `RUN` is preset at the 74S74 at OLORD1 1A14 by
// `-BOOT`, and what this asks is whether a machine whose button has never been
// pressed sits still.
//
// **WHAT IT HOLDS TO, AND IT IS muir'S OWN WORDS.**  `--no-auto-boot` in
// `../muir/src/main.rs` says: "leave the boot button unpressed, as a CADR is
// when the power comes on: RUN clear and nothing running.  The run starts held
// at the prompt, and boot there presses the button; nothing else starts it".
// So there are three claims and each is a case below.
//
//   1. HELD.  Out of reset with the switch on, the machine retires no
//      microcycles at all and `MACHRUN` never rises.  100,000 ticks is 2,272
//      microcycles of a machine that was running --- measured, and it is 44
//      ticks each because the PROM runs at extra slow --- so a machine that
//      took even one is caught.
//   2. THE BUTTON STARTS IT.  `-BOOT2` pressed and let go, and the boot PROM
//      runs from word 0 --- `PC` 0 then `045` --- with `PROMDISABLE` clear and
//      microcycles retiring at the PROM's own rate afterwards.  A machine that
//      started and stopped again would pass a check that only looked at the
//      PC, so the rate is measured too.
//   3. IT IS A POWER-ON CONDITION AND NOT A CONTROL.  The switch is read at
//      the reset arm of `cadr_spy_registers.sv` and at no other instant, so
//      moving it under a running machine does nothing until the next reset,
//      and moving it back under a HELD machine does not start one.  Both
//      directions are asserted, because either one alone is passed by a fabric
//      that reads the level live in the other direction only.
//
// And the control: with the switch off the machine comes up exactly as it
// always has, which is what every trace in this repository starts from.  A
// check that only ran the held case would pass a fabric that never runs.
//
// **NO MEMORY, ON PURPOSE**, for `cadr_kbd_boot_tb.cpp`'s reason: the boot
// PROM's first main-memory cycle is at microcycle 536,303 and nothing here
// gets near it, so `mem_done` is held low and nothing ever asks.
//
// Build and run:
//     verilator --cc --exe --build -Wall -Wno-fatal \
//         -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
//         -Mdir build/obj_no_auto_boot \
//         -GPROM_HEX='"'"$PWD"'/build/boot_prom.hex"' \
//         --top-module cadr_machine <the machine's sources> \
//         "$PWD"/tb/cadr_no_auto_boot_tb.cpp
//     build/obj_no_auto_boot/Vcadr_machine

#include <cstdio>
#include <cstdlib>
#include <vector>
#include "Vcadr_machine.h"
#include "verilated.h"

namespace {

// How long a held machine is watched.  A running machine retires 2,272
// microcycles in this --- 44 ticks each, the PROM's extra slow --- so "no
// microcycles" is a strong claim rather than a short window that happened to
// catch none.  The control below measures that figure rather than assuming it.
constexpr long kHeldT = 100000;

int bad = 0;

void Fail(const char *what, long got, long want) {
  std::fprintf(stderr, "FAIL: %s is %ld, wanted %ld\n", what, got, want);
  ++bad;
}

struct Mach {
  Vcadr_machine *d;
  long tick = 0, micro = 0;
  // Every tick `MACHRUN` was up since `ClearWitness()`, and every tick the
  // machine retired a microcycle in.  A held machine must have neither.
  long machrun_ticks = 0;
  std::vector<unsigned> seen;
  bool watching = false;
  // How long reset is held.  Eight ticks, as every other check here holds it,
  // and the switch is read at the last of them.
  long reset_t = 8;

  explicit Mach(int hold) : d(new Vcadr_machine) {
    d->clk = 0;
    d->rst = 1;
    d->no_auto_boot = hold ? 1 : 0;
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
      d->rst = (tick < reset_t);
      d->clk = 1;
      d->eval();
      if (d->clock_edge) ++micro;
      if (d->machrun) ++machrun_ticks;
      if (watching && (seen.empty() || seen.back() != d->pc)) seen.push_back(d->pc);
      d->clk = 0;
      d->eval();
      ++tick;
    }
  }

  void Watch() {
    seen.clear();
    watching = true;
  }

  void ClearWitness() {
    machrun_ticks = 0;
  }

  // Whether the PROM's own start is among the PCs seen: 0, then `045`.
  // `cadr_kbd_boot_tb.cpp` has the derivation --- word 0 of the PROM is
  // `jump 45`, so a machine that has taken the boot trap shows 0 then 045,
  // and nothing in `promh.text` reaches 0 any other way.
  bool StartedThePROM() const {
    for (size_t i = 0; i + 1 < seen.size(); ++i) {
      if (seen[i] != 0) continue;
      if (seen[i + 1] == 045) return true;
      if (seen[i + 1] == 1 && i + 2 < seen.size() && seen[i + 2] == 045) return true;
    }
    return false;
  }

  void SayPCs(const char *what) const {
    std::fprintf(stderr, "  %s saw:", what);
    for (size_t i = 0; i < seen.size() && i < 12; ++i) std::fprintf(stderr, " %o", seen[i]);
    std::fprintf(stderr, "\n");
  }
};

// A machine that is standing still: no microcycle retired and `MACHRUN` never
// up over the window.  Both, because either alone is weaker than the pair ---
// a fabric whose `clock_edge` were stuck low would pass the first, and one
// whose run signal were inverted would pass the second.
void MustStandStill(Mach &m, long ticks, const char *what) {
  const long before = m.micro;
  m.ClearWitness();
  m.Step(ticks);
  if (m.micro != before)
    Fail(what, m.micro - before, 0);
  if (m.machrun_ticks != 0) {
    std::fprintf(stderr, "FAIL: %s: MACHRUN was up for %ld of %ld ticks\n",
                 what, m.machrun_ticks, ticks);
    ++bad;
  }
}

// A machine that is running: microcycles at the PROM's own rate.  29 ticks a
// microcycle at normal speed and 44 at extra slow, which is what the PROM
// runs at, so a machine that is running retires at least one per 64 ticks even
// with a stall in the way.  The bound is deliberately loose: what this asks is
// whether the machine is running at all, and the case above asks the rate.
long MustRun(Mach &m, long ticks, const char *what) {
  const long before = m.micro;
  m.Step(ticks);
  const long got = m.micro - before;
  if (got < ticks / 64) Fail(what, got, ticks / 64);
  return got;
}

// The light panel's button, pressed and let go.  `-BOOT2` is a level: a finger
// holds it, the machine stands at the boot trap while it is down, and the PROM
// runs from word 0 when it goes up.
void PressTheButton(Mach &m) {
  m.d->n_boot2 = 0;
  m.Step(2000);
  m.Watch();
  m.d->n_boot2 = 1;
  m.Step(4000);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  // --- 1.  THE CONTROL, FIRST: with the switch off nothing changed.
  //
  // It runs first deliberately.  Every case below asserts that a machine does
  // not run, and a fabric that never runs at all passes all of them; this is
  // the one that says the PROM works in this harness in the first place.
  long free_rate = 0;
  {
    Mach m(0);
    m.Step(64);
    free_rate = MustRun(m, kHeldT, "microcycles in 100,000 ticks with the switch off");
    if (m.machrun_ticks == 0) {
      std::fprintf(stderr, "FAIL: MACHRUN was never up on a machine that boots itself\n");
      ++bad;
    }
    if (m.d->promdisable) Fail("PROMDISABLE on a machine running its PROM", m.d->promdisable, 0);
    std::printf("    %ld microcycles in %ld ticks with the switch off.\n", free_rate, kHeldT);
  }

  // --- 2.  HELD: with the switch on the machine comes up stopped.
  //
  // `RUN` clear and nothing running, which is muir's own sentence for it.
  {
    Mach m(1);
    MustStandStill(m, kHeldT, "microcycles retired by a held machine");
    // And the PROM has not run: `PC` has never left 0, so nothing of the
    // machine's own state has moved either.
    if (m.d->pc != 0) Fail("PC on a held machine", m.d->pc, 0);
  }

  // --- 3.  AND THE BUTTON STARTS IT.
  //
  // The hold is taken off by `-BOOT` and by nothing else, so this is the one
  // case that must run.  The PROM from word 0, `PROMDISABLE` clear, and the
  // machine still going afterwards at the rate case 1 measured --- a boot that
  // started the machine for two microcycles and stopped would pass a check
  // that only looked at the PC.
  {
    Mach m(1);
    MustStandStill(m, kHeldT, "microcycles retired before the button was pressed");
    PressTheButton(m);
    if (!m.StartedThePROM()) {
      std::fprintf(stderr, "FAIL: the held machine did not start the PROM at the button\n");
      m.SayPCs("the button on a held machine");
      ++bad;
    }
    if (m.d->promdisable) Fail("PROMDISABLE after the button", m.d->promdisable, 0);
    const long after = MustRun(m, kHeldT, "microcycles in 100,000 ticks after the button");
    if (after < free_rate - 2 || after > free_rate + 2)
      Fail("microcycles in 100,000 ticks after the button", after, free_rate);
    std::printf("    %ld microcycles in %ld ticks after the button, against %ld free.\n",
                after, kHeldT, free_rate);
  }

  // --- 4.  THE SWITCH IS READ AT RESET AND AT NO OTHER INSTANT.
  //
  // Raised under a running machine it must do nothing: a machine that stopped
  // mid-instruction because somebody moved a switch would be a control the
  // CADR never had, and this fabric's whole rule is that the switch says how
  // the machine COMES UP.
  {
    Mach m(0);
    m.Step(64);
    MustRun(m, 20000, "microcycles before the switch was raised");
    m.d->no_auto_boot = 1;
    const long got = MustRun(m, kHeldT, "microcycles after the switch was raised live");
    std::printf("    %ld microcycles in %ld ticks with the switch raised under a running\n"
                "    machine, which is the same machine.\n", got, kHeldT);
  }

  // --- 5.  AND LOWERED UNDER A HELD MACHINE IT DOES NOT START ONE.
  //
  // The other direction, and it is not the same claim: a fabric that took the
  // level live in one direction only passes case 4 or this one but not both.
  // Only `-BOOT` takes the hold off, which is what "the button starts it"
  // means.
  {
    Mach m(1);
    MustStandStill(m, 20000, "microcycles retired by a held machine");
    m.d->no_auto_boot = 0;
    MustStandStill(m, kHeldT, "microcycles retired after the switch was lowered live");
    if (m.d->pc != 0) Fail("PC after the switch was lowered under a held machine", m.d->pc, 0);
    // And the button still works afterwards, so what case 3 showed is not
    // spent by moving the switch about.
    PressTheButton(m);
    if (!m.StartedThePROM()) {
      std::fprintf(stderr, "FAIL: the button did not start a machine whose switch had been lowered\n");
      m.SayPCs("the button after the switch was lowered");
      ++bad;
    }
  }

  if (bad) {
    std::fprintf(stderr, "FAIL: %d checks failed\n", bad);
    return 1;
  }
  std::printf(
      "ok: the no-auto-boot switch leaves the machine as a CADR is when the power comes on.\n"
      "    With the switch off the boot PROM runs and retires %ld microcycles in %ld ticks,\n"
      "    which is the control and the state every trace here starts from.\n"
      "    With it on the machine comes out of reset with RUN clear: no microcycle retired\n"
      "    in %ld ticks, MACHRUN never up, PC never off 0 --- muir's own --no-auto-boot.\n"
      "    -BOOT2 pressed and let go starts the PROM from word 0, PC 0 then 045, with\n"
      "    PROMDISABLE clear and the machine going on at the rate the control measured.\n"
      "    And the switch is read at reset and at no other instant: raised under a running\n"
      "    machine it does nothing, lowered under a held one it starts nothing, and only\n"
      "    the button takes the hold off.\n",
      free_rate, kHeldT, kHeldT);
  return 0;
}
