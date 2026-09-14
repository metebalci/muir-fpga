// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// LD4, the lamp that says the machine fell over.
//
// The DUT is `rtl/plumbing/cadr_lamp_errhalt.sv`, which is four lines and is a
// module for exactly this reason: in the top level those four lines would be
// reached by the `arty` lint and by nothing else, and lint cannot tell a lamp
// that latches from one that does not.
//
// **WHAT IS HELD HERE AND WHAT IS NOT.**  Held: dark at reset, lit by
// `ERRHALT`, STILL lit after `ERRHALT` goes away, dark again at `-BOOT` and at
// a reset, and dark again after the button is let go.  Not held here, and it
// cannot be: WHICH signal the board wires to the input.  That is
// `boards/arty-z7-20/cadr_arty.sv`'s and the `arty` lint's, and that file says
// so at the instantiation.  The claim "and nothing else" is carried by the
// port list --- a module with one input cannot be lit by a signal it does not
// have --- which is why the input is `errhalt` alone and not four signals
// three of which are ignored.
//
// Build and run:
//     verilator --cc --exe --build -Wall -Mdir build/obj_errhalt_lamp \
//         --top-module cadr_lamp_errhalt rtl/plumbing/cadr_lamp_errhalt.sv \
//         "$PWD"/tb/cadr_lamp_errhalt_tb.cpp
//     build/obj_errhalt_lamp/Vcadr_lamp_errhalt

#include <cstdio>
#include "Vcadr_lamp_errhalt.h"
#include "verilated.h"

namespace {

int bad = 0;
long tick = 0;

void Fail(const char *what, int got, int want) {
  std::fprintf(stderr, "FAIL: %s is %d, wanted %d\n", what, got, want);
  ++bad;
}

struct Lamp {
  Vcadr_lamp_errhalt *d;

  Lamp() : d(new Vcadr_lamp_errhalt) {
    d->clk = 0;
    d->rst = 1;
    d->errhalt = 0;
    d->n_boot = 1;
    d->eval();
    Step(8);
    d->rst = 0;
    Step(2);
  }
  ~Lamp() { d->final(); delete d; }

  void Step(long n) {
    for (long k = 0; k < n; ++k) {
      d->clk = 1;
      d->eval();
      d->clk = 0;
      d->eval();
      ++tick;
    }
  }
  int Lit() const { return d->lit; }
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Lamp l;

  // --- 1.  DARK OUT OF RESET.  Dark is the good state, and a lamp that came
  // up red would be a board that always looks broken.
  if (l.Lit()) Fail("the lamp out of reset", l.Lit(), 0);

  // --- 2.  A HALT WITH NOTHING ELSE HAPPENING DOES NOT LIGHT IT.
  // A thousand ticks of a machine running normally.
  l.Step(1000);
  if (l.Lit()) Fail("the lamp on a machine that has not halted", l.Lit(), 0);

  // --- 3.  `ERRHALT` LIGHTS IT, AT THE NEXT TICK AND NOT LATER.
  l.d->errhalt = 1;
  l.Step(1);
  if (!l.Lit()) Fail("the lamp one tick after ERRHALT", l.Lit(), 1);

  // --- 4.  AND IT STAYS LIT WHEN `ERRHALT` GOES AWAY.
  //
  // This is the whole reason for the latch.  `-BOOT` clears `ERRSTOP` at the
  // mode register, so the machine's own `ERRHALT` drops by itself --- but so
  // does a console that writes the mode register for a reason of its own, with
  // the machine still standing where it fell.  What a person at the board saw
  // must not be erased by somebody else's register write.
  l.d->errhalt = 0;
  l.Step(10000);
  if (!l.Lit()) Fail("the lamp 10,000 ticks after ERRHALT went away", l.Lit(), 1);

  // --- 5.  THE BUTTON PUTS IT OUT, AND IT STAYS OUT.
  //
  // `-BOOT` is a level: a finger holds it.  The lamp must go out at the press
  // and must still be out after the release, or a boot would leave a board
  // that reads as broken.
  l.d->n_boot = 0;
  l.Step(1);
  if (l.Lit()) Fail("the lamp one tick after -BOOT", l.Lit(), 0);
  l.Step(400);
  l.d->n_boot = 1;
  l.Step(10000);
  if (l.Lit()) Fail("the lamp after the button was let go", l.Lit(), 0);

  // --- 6.  AND A HALT UNDER A HELD BUTTON DOES NOT LIGHT IT.
  //
  // The clear is dominant, which is what a lamp cleared by the button means.
  l.d->n_boot = 0;
  l.d->errhalt = 1;
  l.Step(100);
  if (l.Lit()) Fail("the lamp while the button is held down", l.Lit(), 0);
  // Let go with `ERRHALT` still up and it lights again: the machine is still
  // halted, so the lamp is telling the truth.
  l.d->n_boot = 1;
  l.Step(2);
  if (!l.Lit()) Fail("the lamp after the button was let go with ERRHALT still up",
                     l.Lit(), 1);

  // --- 7.  A RESET PUTS IT OUT TOO.
  l.d->errhalt = 0;
  l.d->rst = 1;
  l.Step(4);
  l.d->rst = 0;
  l.Step(4);
  if (l.Lit()) Fail("the lamp after a reset", l.Lit(), 0);

  // --- 8.  AND THE LAMP IS NOT A ONE-SHOT: a second halt lights it again.
  //
  // Without this a lamp that latched once and never again would pass every
  // case above.
  l.d->errhalt = 1;
  l.Step(1);
  if (!l.Lit()) Fail("the lamp at a second ERRHALT", l.Lit(), 1);
  l.d->errhalt = 0;
  l.Step(1000);
  if (!l.Lit()) Fail("the lamp after the second ERRHALT went away", l.Lit(), 1);

  if (bad) {
    std::fprintf(stderr, "FAIL: %d checks failed\n", bad);
    return 1;
  }
  std::printf(
      "ok: LD4 is the machine's own error halt and nothing else, over %ld ticks.\n"
      "    Dark out of reset and dark while the machine runs; lit one tick after ERRHALT;\n"
      "    still lit 10,000 ticks after ERRHALT goes away, so a console clearing ERRSTOP\n"
      "    cannot erase what somebody saw; out at -BOOT and still out when the button is\n"
      "    let go; not lit while the button is held; out at a reset; and lit again at the\n"
      "    next halt, so it is a lamp and not a one-shot.\n"
      "    Which signal the board wires to it is boards/arty-z7-20/cadr_arty.sv's, held by\n"
      "    build/arty.pass's lint and by nothing here.\n",
      tick);
  return 0;
}
