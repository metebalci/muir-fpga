// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// LD4: the machine fell over.  One input, one lamp, and nothing else.
//
// **WHAT THE LAMP MEANS.**  `ERRHALT` is `ERRSTOP AND HALTED` at OLORD1 ---
// the machine stopping ITSELF because it executed a halt with the console's
// error-stop bit set.  On microcode 323 that is `(si:%halt)` reached through
// `ILLOP`, `%HALT` and `ZERO`; on MIT's own boards the parity checkers reach
// the same line, and this fabric has no parity checkers, so here it is the
// microcode's own halt and only that.  It is one of `MACHRUN`'s terms, so the
// machine is standing still whenever it is up.
//
// **AND WHAT IT DOES NOT MEAN, WHICH IS THE DECISION THIS MODULE EXISTS FOR.**
// The lamp used to be lit by a non-existent-memory timeout, by a block the
// disk's store could not supply, and by the statistics counter running out, as
// well as by this.  A lamp that means four things is read more slowly than one
// that means one, and two of those four are not troubles at all: the boot PROM
// makes two cycles to empty Xbus space on every boot, so the lamp came up red
// on a machine that was perfectly well, and a statistics halt is something the
// console asked for.  **A lamp whose normal state is red says nothing.**  So
// the lamp is this signal and this signal alone, and the port list is that
// claim: a module with one input cannot be lit by a signal it does not have.
//
// **THE DISK'S SILENT DENIAL IS NOT ANSWERED BY TAKING IT OFF THE LAMP.**
// `store_miss` says the block store could not supply a block the channel asked
// for, and the controller ends that transfer with a clean status --- so the
// microcode believes it read a page that was never written and nothing the
// CADR can read says otherwise.  That is a defect of
// `rtl/machine/cadr_disk_controller.sv`, which should set a transfer error the
// machine can see, and it is open there.  A board lamp was never a fix for it
// and showing it here only made the lamp mean two things.
//
// **STICKY, AND CLEARED BY THE BUTTON OR BY A RESET.**  `-BOOT` clears
// `ERRSTOP` at the mode register, so the machine's own signal goes out at a
// boot by itself; a console that merely clears `ERRSTOP` over the diagnostic
// bus would put the lamp out too, with the machine still standing where it
// fell.  The latch is what stops that: what a person at the board saw is not
// erased by somebody else's register write, and the two things that clear it
// are the two that put the machine back at the beginning.
//
// **DARK IS THE GOOD STATE**, which is the whole argument for the lamp.  It is
// the one nobody should have to watch, and it is what makes the microcycle
// lamp's freeze readable: stopped with this dark means somebody halted the
// machine, stopped with this red means it fell over.
//
// **WHY IT IS A MODULE AND NOT FOUR LINES IN THE TOP LEVEL.**  Four lines in
// `boards/arty-z7-20/cadr_arty.sv` are reached by the `arty` lint and by
// nothing else, and lint cannot tell a lamp that latches from one that does
// not.  Here `build/errhalt_lamp.pass` can.  What stays lint-only is the
// WIRING --- which signal reaches this input on the board --- and
// `cadr_arty.sv` says so where it instantiates this.

`default_nettype none

module cadr_lamp_errhalt (
    input  var logic clk,      // 100 MHz, one tick = 10 ns
    input  var logic rst,      // the board's reset: MMCM lock, BTN1, the console's

    // `ERRHALT` out of `cadr_machine`, a level: the machine has halted itself
    // under ERRSTOP and is standing there.
    input  var logic errhalt,

    // `-BOOT`, active low, out of `cadr_machine`: the light panel's button,
    // the keyboard's chord or the debug cable, and nothing here can tell which.
    input  var logic n_boot,

    // The lamp.  High lights it, and the board drives it onto LD4's red pin.
    output var logic lit
);

  always_ff @(posedge clk) begin
    if (rst || !n_boot) lit <= 1'b0;
    else if (errhalt) lit <= 1'b1;
  end

endmodule

`default_nettype wire
