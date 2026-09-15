// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The boot lines, on the whole machine: the keyboard's word and the light
// panel's button, each restarting the boot PROM from word 0.
//
// The DUT is `rtl/machine/cadr_machine.sv` --- the processor, the memory
// path, the bus interface and the I/O board under one roof --- running MIT's
// boot PROM from reset.  `build/iob.pass` holds the card's own decode of the
// boot word against muir over 82 million ticks and says nothing about what
// the pulse then reaches; this is the other half, and the two together are
// the path `docs/keyboard-boot.md` in muir draws link by link.
//
// **WHAT THIS HOLDS TO, AND IT IS muir'S OWN TEST ONE LEVEL UP.**
// `tests/keyboard_boot.rs`'s `boots_again` runs the PROM on `micro` and on
// `rtl`, delivers the boot word through a `Keyboard` and the behavioral I/O
// board, and sees `RUN` preset, `PROMDISABLE` clear, the PC at 0 and then 45,
// and the boot word still readable in the card's register.  Its
// `the_boot_word_boots_the_netlist_machine_through_the_far_end` does the same
// on `chip` with the netlist board on a cable, and watches `-BOOT1` and
// `-BOOT` follow `-BOOT*` low for 4 us.  This check is the same claim about
// this fabric: a word at the keyboard's cable, and the PROM runs from 0.
//
// **THE PC SEQUENCE IS MIT'S OWN AND IS WHY 0 THEN 45 IS THE TEST.**  Word 0
// of the PROM is `jump 45`, so a machine that has taken the boot trap shows
// `PC` 0 and then `045`; muir's `starts_the_prom` allows the nopped 1 between
// them where an engine counts it, and this fabric does not count it, the trap
// forcing `NPC` to zero and the jump loading 45 at the next boundary.
//
// **NO MEMORY, ON PURPOSE.**  The boot PROM's first main-memory cycle is at
// microcycle 536,303, which is 118 ms of machine time; everything this check
// is about happens in the first few thousand microcycles, so `mem_done` is
// held low and nothing ever asks.  `build/ddr_boot.pass` is the check that
// runs the PROM into real memory; this one runs it into the boot trap.
//
// **WHAT IS COMPARED AGAINST WHAT.**  The card's decode is muir's, checked in
// `build/iob.pass`; the words here are the ones muir's
// `terminal::keyboard::boot` builds, written out in octal with their
// derivation, because a testbench that computed them from the same rule the
// fabric uses would be comparing the fabric with itself.
//
//   cold  0o76376046   bits 23-19 the frame's reserved ones, 18-16 the new
//   warm  0o76376062   keyboard's source 001, 15-10 ones, 9-6 zeros, and
//                      5-0 `46` octal for cold or `62` for warm
//
// Build and run:
//     verilator --cc --exe --build -Wall -Wno-fatal \
//         -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
//         -Mdir build/obj_kbd_boot \
//         -GPROM_HEX='"'"$PWD"'/build/boot_prom.hex"' \
//         --top-module cadr_machine <the machine's sources> \
//         "$PWD"/tb/cadr_kbd_boot_tb.cpp
//     build/obj_kbd_boot/Vcadr_machine

#include <cstdio>
#include <cstdlib>
#include <vector>
#include "Vcadr_machine.h"
#include "verilated.h"

namespace {

// muir's `terminal::keyboard::boot`, written out rather than computed.
constexpr unsigned kCold = 076376046u;
constexpr unsigned kWarm = 076376062u;
// A word off the same keyboard that is not the boot word: Rubout going down,
// `up_down(0o23, false)` = the frame with position 23 in it.  The comparator's
// window, bits 13-6, is zero in it.
constexpr unsigned kRubout = 076200023u;

// `KBD READY` in `csr_face`, which is `{ser_en, 1'b0, kbd_ready, mouse_ready,
// en175}` --- bit 5.
constexpr unsigned kKbdReady = 1u << 5;

// How long the card holds `-BOOT*`: half a keyboard clock, 800 ticks.  The
// machine must be given at least that long to see it.
constexpr long kBootPulseT = 800;

int bad = 0;

void Fail(const char *what, long got, long want) {
  std::fprintf(stderr, "FAIL: %s is %ld, wanted %ld\n", what, got, want);
  ++bad;
}

// The machine, with the PROM in it and nothing else.
struct Mach {
  Vcadr_machine *d;
  long tick = 0, micro = 0;
  // The distinct PCs seen since `Watch()` was last called.
  std::vector<unsigned> seen;
  bool watching = false;

  Mach() : d(new Vcadr_machine) {
    d->clk = 0;
    d->rst = 1;
    d->boards = 32;
    d->device_ack = 0;
    d->device_rdata = 0;
    d->mem_done = 0;
    d->mem_rdata = 0;
    // The three boot lines, all released.  `-BOOT2` is the light panel's and
    // this check presses it; the keyboard's `-BOOT1` is made inside, by the
    // card, out of `kbd_strobe`; `PROG.BOOT` needs a mode-register write and
    // `build/console.pass` is where that is pressed.
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
      d->rst = (tick < 8);
      d->clk = 1;
      d->eval();
      if (d->clock_edge) ++micro;
      if (watching && (seen.empty() || seen.back() != d->pc)) seen.push_back(d->pc);
      d->clk = 0;
      d->eval();
      ++tick;
      d->kbd_strobe = 0;
    }
  }

  void Watch() {
    seen.clear();
    watching = true;
  }

  // **ONE DIAGNOSTIC WRITE, OVER THE CONSOLE'S OWN UNIBUS MASTER PORT.**  The
  // check needs `PROMDISABLE` SET before a boot, or its assertion that the
  // boot clears it is an assertion about a bit that was already zero --- the
  // trap this project keeps meeting, and the reason the first run of
  // `boot-promdisable-survives-it` SURVIVED.
  //
  // `cadr_spy_registers.sv` is the slave at `0o766000` and the mode register
  // is `EADR` 5, the registers two bytes apart, so `0o766012`; bit 5 is
  // `PROMDISABLE`.  The handshake is the Unibus's own: ask for the bus, wait
  // for the grant, raise `-UB MSYN` with the address and the word, wait for
  // `-UB SSYN`, and let go.  It is bounded at every wait, so a fabric that
  // never grants or never answers fails here rather than hanging.
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

  // The card takes a word off the keyboard's cable: one tick of `kbd_strobe`,
  // which is the `KEY` row of `build/iob.golden`.
  void Type(unsigned word) {
    d->kbd_strobe = 1;
    d->kbd_code = word;
    Step(1);
  }

  // Whether the PROM's own start is among the PCs seen: 0, then `045`.
  bool StartedThePROM() const {
    for (size_t i = 0; i + 1 < seen.size(); ++i) {
      if (seen[i] != 0) continue;
      if (seen[i + 1] == 045) return true;
      // muir allows the nopped 1 behind the jump where an engine counts it.
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

// Runs the PROM well clear of its own start, so that "back at 0" means
// something.  4,000 microcycles is about 0.9 ms of machine time and the PROM
// is deep in its register self-test by then.
void Settle(Mach &m) {
  const long from = m.micro;
  while (m.micro < from + 4000) m.Step(64);
  if (m.d->pc == 0) Fail("the PROM's PC before the boot", m.d->pc, 1);
}

// **THE KEYBOARD'S BOOT WORD RESTARTS THE PROM.**  The card decodes it, pulls
// `-BOOT*` for 4 us, the 74S02 at OLORD2 1A07 makes `-BOOT`, and the PROM runs
// from word 0.  The word stays in the card's register with `KBD READY` up,
// which is what microcode 323 reads at `(LOC 6)` to choose cold from warm.
void KeyboardBoots(Mach &m, unsigned word, const char *what) {
  Settle(m);
  // **THE REAL PROM RUNS UNDER THIS TEST, AND THAT IS DELIBERATE.**  An
  // earlier draft set `PROMDISABLE` here so that the boot would have
  // something to clear, and it made the test LUCKY: with the PROM off the
  // machine executes the control store, which comes up all ones, and an
  // all-ones word is a `POPJ` onto a stack pointer of zero --- so the PC
  // reaches 0 on its own and `0 then 45` appears with no trap at all.
  // Measured: `boot-the-trap-is-not-raised` passed the cold and warm rows
  // that way.  On the PROM 0 is reachable only through the trap, because
  // nothing in `promh.text` jumps there.  `PROMDISABLE` has its own test
  // below, where the PC is not looked at.
  m.Watch();
  m.Type(word);
  // Through the pulse and a few microcycles past it.
  m.Step(kBootPulseT + 4000);
  if (!m.StartedThePROM()) {
    std::fprintf(stderr, "FAIL: %s: the PROM did not start from 0\n", what);
    m.SayPCs(what);
    ++bad;
  }
  if ((m.d->csr_face & kKbdReady) == 0)
    Fail("KBD READY after the boot word", m.d->csr_face, kKbdReady);
  if (m.d->promdisable) Fail("PROMDISABLE after the boot", m.d->promdisable, 0);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  // --- 1.  The cold word, and 2. the warm one.
  {
    Mach m;
    KeyboardBoots(m, kCold, "the cold boot word");
  }
  {
    Mach m;
    KeyboardBoots(m, kWarm, "the warm boot word");
  }

  // --- 3.  AND A BOOT PUTS THE BOOT PROM BACK OVER THE CONTROL STORE.
  //
  // `-BOOT` is one of the three inputs of `RESET` at the 74S10 at OLORD2
  // 1C08, and `RESET` clears the two 74S175s of the console's registers with
  // `PROMDISABLE` among them.  muir's `tests/keyboard_boot.rs` asserts
  // `!f.promdisable` after the boot word on both engines.
  //
  // It is set here over the console's own Unibus master port, because a bit
  // that was already zero cannot be shown to have been cleared.  **The PC is
  // not looked at in this block**: with the PROM off the machine is executing
  // the control store, and where that takes it is not this check's business.
  {
    Mach m;
    Settle(m);
    if (!m.UnibusWrite(0766012, 040))
      Fail("the mode-register write was answered", 0, 1);
    m.Step(3 * 44);
    if (!m.d->promdisable) Fail("PROMDISABLE before the boot word", m.d->promdisable, 1);
    m.Type(kCold);
    m.Step(kBootPulseT + 44);
    if (m.d->promdisable)
      Fail("PROMDISABLE after the keyboard's boot word", m.d->promdisable, 0);
    if ((m.d->csr_face & kKbdReady) == 0)
      Fail("KBD READY after the boot that cleared PROMDISABLE", m.d->csr_face, kKbdReady);
  }

  // --- 4.  THE CONTROL: an ordinary word must not boot anything.
  //
  // Without this the check passes on a card that boots on every keystroke,
  // which is the failure MIT's own ECO#3 of 30 January 1980 warns about at
  // the other end --- "increases the chance of the old keyboard rebooting the
  // machine accidentally".
  {
    Mach m;
    Settle(m);
    m.Watch();
    m.Type(kRubout);
    m.Step(kBootPulseT + 4000);
    if (m.StartedThePROM()) {
      std::fprintf(stderr, "FAIL: Rubout going down restarted the PROM\n");
      m.SayPCs("Rubout down");
      ++bad;
    }
    if ((m.d->csr_face & kKbdReady) == 0)
      Fail("KBD READY after an ordinary word", m.d->csr_face, kKbdReady);
  }

  // --- 5.  THE LIGHT PANEL'S BUTTON, HELD AND LET GO.
  //
  // `-BOOT2` is a level, not a pulse: a finger holds it.  While it is held the
  // machine stands at the boot trap with `NPC` forced to zero and every
  // microcycle nopped, so `PC` is 0 and stays 0; when it is let go the PROM
  // runs from word 0.  That is what muir's `chip` test does between its press
  // and its release, and it is what `boards/arty-z7-20/cadr_arty.sv` wires
  // BTN0 and the console's word 13 to.
  {
    Mach m;
    Settle(m);
    m.d->n_boot2 = 0;
    m.Step(4000);
    if (m.d->pc != 0) Fail("PC while the boot button is held", m.d->pc, 0);
    // Held longer still: a machine that ran on under a held button would show
    // it here and not at the release.
    m.Step(20000);
    if (m.d->pc != 0) Fail("PC after the button has been held 24,000 ticks", m.d->pc, 0);
    if (m.d->promdisable) Fail("PROMDISABLE while the button is held", m.d->promdisable, 0);
    m.Watch();
    m.d->n_boot2 = 1;
    m.Step(4000);
    if (!m.StartedThePROM()) {
      std::fprintf(stderr, "FAIL: the PROM did not start when the button was let go\n");
      m.SayPCs("the button released");
      ++bad;
    }
  }

  // --- 6.  AND THE MACHINE GOES ON RUNNING AFTERWARDS.
  //
  // A boot that stopped the machine would pass every test above: `PC` 0 then
  // 45 and nothing more is a machine that took two microcycles and died.  So
  // the last thing is a plain count: the PROM must retire microcycles at its
  // own rate after a boot, as it did before one.
  {
    Mach m;
    Settle(m);
    const long before = m.micro;
    m.Step(100000);
    const long rate_before = m.micro - before;
    m.Type(kCold);
    m.Step(kBootPulseT);
    const long after = m.micro;
    m.Step(100000);
    const long rate_after = m.micro - after;
    if (rate_before < 1000) Fail("microcycles in 100,000 ticks before the boot", rate_before, 1000);
    // The same program at the same speed: within a microcycle of each other,
    // the two runs starting at different phases of the generator.
    if (rate_after < rate_before - 2 || rate_after > rate_before + 2)
      Fail("microcycles in 100,000 ticks after the boot", rate_after, rate_before);
    std::printf("    %ld microcycles in 100,000 ticks before the boot and %ld after.\n",
                rate_before, rate_after);
  }

  if (bad) {
    std::fprintf(stderr, "FAIL: %d checks failed\n", bad);
    return 1;
  }
  std::printf(
      "ok: the two boot lines reach the processor on the whole machine.\n"
      "    The keyboard's cold word (0%o) and warm word (0%o) are decoded by the card, pulse\n"
      "    -BOOT* for %ld ticks, and the boot PROM runs from word 0 again --- PC 0 then 045,\n"
      "    muir's own test in tests/keyboard_boot.rs --- with PROMDISABLE clear and the word\n"
      "    still in the card's register with KBD READY up, for (LOC 6) to read.\n"
      "    PROMDISABLE is SET over the console's own Unibus port in a test of its own and\n"
      "    the boot clears it, so that is a measurement and not a comparison of zero with\n"
      "    zero; the PC is not looked at there, the machine being off the PROM.\n"
      "    Rubout going down (0%o) is decoded and boots nothing, which is the control.\n"
      "    The light panel's -BOOT2 held keeps PC at 0 for 24,000 ticks and letting it go\n"
      "    starts the PROM, which is what a finger on a button does.\n",
      kCold, kWarm, kBootPulseT, kRubout);
  return 0;
}
