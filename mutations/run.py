# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The checks, checked.
#
# `make check` passing says the fabric agrees with muir.  It says nothing about
# whether it would still pass if the fabric were wrong, and that is the claim
# the whole project rests on.  So: take each check, break the design it is
# holding, and see whether it notices.  A mutation the check catches is a
# check earning its keep; one it does not is a hole.
#
# Every mutation in list.txt is a bug in the fabric, and most of them are bugs
# that were really made --- this project's record of what went wrong and what
# caught it is the seed of the list, because each of those passed something
# before it was found.
#
# THE WORKING TREE IS NEVER MUTATED.  Each mutation gets a copy of rtl/ and
# tb/ under --work and is applied, built and run there.  The tree is shared
# with other sessions; a runner that edited it in place and then crashed would
# leave corrupted source behind.
#
# THREE THINGS ARE FAILURES OF THE RUN, NOT CAUGHT MUTATIONS, and each exits
# non-zero with the mutation named:
#
#   the mutation did not apply --- its `@old` text is not in the file, or is
#   there more than once.  Silently mutating nothing would give a clean build,
#   a passing check, and a report of SURVIVED: a finding that is not real.
#
#   the build failed.  This is `docs/mutations.md`'s rule that a build
#   failure is never a catch, from the other side: two mutations were once
#   reported as surviving when lint had rejected them and a stale binary
#   ran.  Nothing here reuses a build directory, and a build that fails is
#   reported as BROKEN rather than as anything else.
#
#   the baseline failed.  Before any mutation runs, the unmutated copy has to
#   pass every check that has mutations against it.  "The check caught it" is
#   worth nothing from a check that was already failing.
#
# A mutation that survives is a finding.  It is not tuned away and not dropped
# from the list: it says a check is weaker than it looks, and the fix belongs
# in the check.
#
# WHAT `@hole` IS FOR, and why it is not a way to hide one.  A check that is
# known not to catch something, with an issue saying so, is a recorded
# exception --- the same shape as the recorded partings of the fabric from
# muir, or the testbench not comparing -TPR60 while RESET is high.  What the
# repository does not tolerate is an *unrecorded* one.
#
# The reason to have the field at all is that a target which is red by design
# cannot report a fifth survivor: red for four known reasons looks exactly
# like red for five, and a mutation runner that can no longer deliver a new
# finding has stopped being a check and become a reminder.  So a survivor
# carrying `@hole #3` is reported, counted in its own column, and tolerated.
#
# And the inverse, which is what keeps it honest: a mutation that is CAUGHT
# while still carrying an `@hole` fails the run, naming the issue to close and
# the line to delete.  Without that, suppressions outlive the holes they
# describe and the list quietly becomes a lie.

import argparse
import concurrent.futures
import filecmp
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
LIST = os.path.join(HERE, "list.txt")

# The six checks stage 3 froze, exactly as the Makefile builds them.  Kept
# beside it by hand: two descriptions of one thing, and check_makefile()
# below is what warns when they stop agreeing.
#
#   sources   what verilate, in the Makefile's order
#   tb        the C++ testbench, or None for a lint-only check
#   flags     verilator flags beyond VFLAGS
#   golden    the reference trace the testbench is given, or None
#
# `microcycle` is deliberately absent.  Stage 4 is being written right now and
# is not frozen; it gets mutations when a slice lands.
# `M_AXI_GP0` split five ways, named once because it goes on every board that
# brings the port out.  The Makefile's own `GP0` is the same list.
# The display output, as `arty.pass`'s sixth board lints it: the two plain
# modules, the encoder under them, and the Xilinx-specific phy last because
# it is the only one that needs the primitive stubs.
DISPLAY = ["rtl/plumbing/cadr_display_out.sv", "rtl/plumbing/cadr_tmds_encode.sv",
           "rtl/plumbing/cadr_hdmi_tx.sv", "rtl/plumbing/xilinx7/cadr_hdmi_phy.sv"]

GP0 = ["rtl/plumbing/cadr_gp0_split.sv", "rtl/plumbing/cadr_gp_regs.sv",
       "rtl/plumbing/cadr_chaos_cable.sv", "rtl/plumbing/cadr_serial_line.sv",
       "rtl/plumbing/cadr_input_cables.sv"]

# MIT's grid, `rtl/machine/cadr_tick_pkg.sv`, which the Makefile hands every
# Verilator line as `$(TICKPKG)` ahead of the modules that import it.
#
# **IT IS NOT IN ANY SOURCE LIST ABOVE OR BELOW, AND IT WAS NOT HERE AT ALL
# WHEN IT ARRIVED.**  The package landed in the Makefile and in no list of
# this file's, so every check this runner verilates failed its baseline on
# `%Error-PKGNODECL` and the run exited 2 before a single record: `make
# mutants` was dead while `make check` was green.  Neither guard below could
# say so.  `check_makefile` asks only that every file this runner names is
# mentioned somewhere in the Makefile, which is the other direction, and it
# reads the Makefile's text, where the package is a variable named once;
# `check_coverage` compares these lists with the records and never with the
# Makefile at all.
#
# It goes first on every Verilator command rather than into fifty-four lists,
# because a package nothing imports costs lint nothing and a list that forgot
# it is exactly this failure again.  And only where the copy HAS it, because
# `--since` names revisions older than the package, where a file that is not
# there would make every record BROKEN --- the `git archive` pathspec lesson.
TICK_PKG = "rtl/machine/cadr_tick_pkg.sv"


def tick_pkg(work):
    """The grid's package, if this copy of the tree has one."""
    return [TICK_PKG] if os.path.exists(os.path.join(work, TICK_PKG)) else []

# `machine`'s entry, named once because QUUX's checks are the same build
# with another PROM, another trace and, for QUUX, another `MACHINE`.
MACHINE_CHECK = {
    "sources": [
        "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
        "rtl/plumbing/cadr_ddr_map.sv", "rtl/machine/cadr_xbus_decode.sv",
        "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
        "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_tv.sv",
        "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
    ],
    # Built because `cadr_machine` instantiates it; the console's own
    # check is what holds it, so no mutation is aimed at it here.
    "extra": ["rtl/machine/cadr_console_state.sv"],
    "top": "cadr_machine",
    "tb": "tb/cadr_machine_tb.cpp",
    "flags": ["-O2", "-CFLAGS", "-O2", "+define+CADR_GAP_MONITOR", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
    "golden": "rtl.golden",
    "gprom": True,
}

# The files only a QUUX build compiles: `cadr_machine` names each under
# `MACHINE == "quux"`, and a CADR build finds none of them.
QUUX_SOURCES = ["rtl/machine/quux_feature_page.sv", "rtl/machine/quux_mono_tv.sv",
                "rtl/machine/quux_muldiv.sv", "rtl/machine/quux_phase_gen.sv",
                "rtl/machine/quux_clocks.sv", "rtl/machine/quux_input.sv",
                "rtl/machine/quux_block_disk.sv"]

CHECKS = {
    "phase_gen": {
        "sources": ["rtl/machine/cadr_phase_gen.sv"],
        "top": "cadr_phase_gen",
        "tb": "tb/cadr_phase_gen_tb.cpp",
        "flags": [],
        "golden": "phase_gen.golden",
    },
    "cables": {
        # Lint alone is not what this check holds to; see cables_check().
        "sources": ["rtl/machine/cadr_cables.svh", "rtl/machine/cadr_cables_lint.sv"],
        "top": "cadr_cables_lint",
        "tb": None,
        "flags": ["-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": None,
    },
    "busint_xbus": {
        "sources": ["rtl/machine/cadr_busint_xbus.sv"],
        "top": "cadr_busint_xbus",
        "tb": "tb/cadr_busint_xbus_tb.cpp",
        "flags": [],
        "golden": "busint_xbus.golden",
    },
    "xbus_decode": {
        "sources": ["rtl/machine/cadr_xbus_decode.sv"],
        "top": "cadr_xbus_decode",
        "tb": "tb/cadr_xbus_decode_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": "xbus_decode.golden",
    },
    "memory_path": {
        "sources": [
            "rtl/plumbing/cadr_ddr_map.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv",
            "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_memory_path.sv",
        ],
        "top": "cadr_memory_path",
        "tb": "tb/cadr_memory_path_tb.cpp",
        "flags": ["-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        # The memory path is driven from the bus interface's own trace: the
        # same stimulus, through the whole path.
        "golden": "busint_xbus.golden",
    },
    # The display controller, `rtl/machine/cadr_tv.sv`, against muir's SimpleTv
    # through Busint --- the same module list as `memory_path`, because the
    # display is instantiated inside it and its frame buffer is the bridge
    # at a second base, so the DUT is the path and not a harness.  Records
    # aimed at the register face, the flag, the frame, the interrupt and the
    # window's base belong here; `memory_path` cannot see the display at all,
    # its trace never addressing it.
    "tv": {
        "sources": [
            "rtl/plumbing/cadr_ddr_map.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv",
            "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_memory_path.sv",
        ],
        "top": "cadr_memory_path",
        "tb": "tb/cadr_tv_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        # **TWO TRACES, ONE A BOARD.**  muir has one display model and
        # `--tv-board` says which board it is playing; the testbench takes
        # each path in turn and straps the fabric from that trace's own
        # header.  A runner that ran one of them would let a mutation of the
        # one bit the two boards differ in --- mode bit 7 --- survive.
        "golden": ["tv.golden", "tv_lispm.golden"],
    },
    # **THE SECOND DISPLAY BOARD**, the color TV, on a backplane that also
    # carries the first.  `golden/src/color_tv.rs` says what the program is;
    # the check holds two instances of `cadr_tv` at two straps, two windows in
    # DDR, the OR of two `-XBUS.INTR`s and the color map --- and, in its
    # configuration B, the backplane with no second board, which is what
    # `COLOR-EXISTS-P` probes for.
    "color_tv": {
        "sources": [
            "rtl/plumbing/cadr_ddr_map.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv",
            "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_memory_path.sv",
        ],
        "top": "cadr_memory_path",
        "tb": "tb/cadr_color_tv_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": "color_tv.golden",
    },
    "axi_master": {
        # No muir reference, so no trace: the testbench is the stimulus.
        "sources": ["rtl/plumbing/cadr_axi_master.sv"],
        "top": "cadr_axi_master",
        "tb": "tb/cadr_axi_master_tb.cpp",
        "flags": [],
        "golden": None,
    },
    # The bridge and the adapter together, when the NXM timer ends a cycle the
    # memory has not answered.  No trace: the testbench's slave is the
    # stimulus, with a latency it sets per cycle.
    "xbus_axi": {
        "sources": ["rtl/plumbing/cadr_ddr_map.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
                    "rtl/plumbing/cadr_axi_master.sv"],
        "extra": ["tb/cadr_xbus_axi_harness.sv"],
        "top": "cadr_xbus_axi_harness",
        "tb": "tb/cadr_xbus_axi_tb.cpp",
        "flags": [],
        "golden": None,
    },
    # The Chaosnet cable's face alone, against overlapping calls.
    "chaos_cable": {
        "sources": ["rtl/plumbing/cadr_chaos_cable.sv", "rtl/plumbing/cadr_gp_regs.sv"],
        "top": "cadr_chaos_cable",
        "tb": "tb/cadr_chaos_cable_tb.cpp",
        "flags": [],
        "golden": None,
    },
    # The 32-bit word in the port's 64-bit beat.  It was six assignments
    # inside `boards/arty-z7-20/cadr_arty.sv`'s `g_ddr`, where nothing could reach it: that
    # file cannot be simulated, so lint and the fitter were the whole of the
    # evidence for it.  A module has a check; a generate block in a top level
    # that Verilator cannot elaborate does not.
    "axi_widen": {
        "sources": ["rtl/plumbing/cadr_axi_widen.sv"],
        "top": "cadr_axi_widen",
        "tb": "tb/cadr_axi_widen_tb.cpp",
        "flags": [],
        "golden": None,
    },
    # The witness that goes on the board ahead of the machine, and the path
    # it drives.  `sources` is the state machine alone, because that is what
    # these mutations are aimed at; the adapter and the widening are in
    # `extra` beside the harness, having checks of their own --- `extra` means
    # here exactly what it means for `arty`, everything the check builds that
    # nothing is aimed at.
    #
    # `tb/cadr_prove_harness.sv` is the wiring, not the thing checked, and it
    # is in `tb/` because both Vivado scripts read `[glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-z7-20/*.sv]`.
    "prove": {
        "sources": ["rtl/plumbing/cadr_prove.sv"],
        "extra": ["rtl/plumbing/cadr_axi_master.sv", "rtl/plumbing/cadr_axi_widen.sv",
                  "tb/cadr_prove_harness.sv"],
        "top": "cadr_prove_harness",
        "tb": "tb/cadr_prove_tb.cpp",
        "flags": ["-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        # No muir reference, so no trace: the testbench is the stimulus and
        # the AXI3 slave underneath it is the observer.
        "golden": None,
    },
    # The processor, twice over: the same module and the same testbench
    # against two programs.  Route a mutation to the cheaper one unless the
    # band is the only thing that reaches what it breaks --- the map, the
    # dispatch memory's read, Q's shifter, the stack RAM, SINTR, -ILONG.
    # The boot PROM is 600,000 microcycles and 84 MB; the band is 2,200,000
    # and 297 MB, and takes about four times as long to run.
    #
    # `files` places what the module reads at elaboration: PROM_HEX defaults
    # to a *relative* build/boot_prom.hex, and the runner builds each mutant
    # with its own copy as the working directory, so the image has to be put
    # where that path resolves.
    "microcycle": {
        "sources": ["rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv"],
        "top": "cadr_microcycle",
        "tb": "tb/cadr_microcycle_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": "rtl.golden",
        "files": [("boot_prom.hex", "build/boot_prom.hex")],
    },
    # THE CLOCK CONTROL REGISTER, WHICH NO REFERENCE PROGRAM CAN REACH.  The
    # boot PROM never writes it and no band does either --- it is the
    # console's register, and a machine running its own microcode has no
    # console --- so `golden/src/sstep.rs` scripts muir's `rtl` engine the way
    # CC does and this compares the fabric row for row against that.  The same
    # module and the same PROM image as the pair above; a different reference
    # and a different testbench.
    #
    # A mutation of the five bits' EFFECT belongs here, where the reference
    # exercises them.  A mutation of the register that HOLDS them belongs at
    # `console` or `unibus`, which build `cadr_spy_registers.sv`.
    # **THE STATE THE MACHINE COMES UP IN**, which is the other half of the
    # boot lines' page: the no-auto-boot switch, `RUN` clear at reset, and the
    # button that takes the hold off.  `cadr_spy_registers.sv` decides `RUN`
    # and `cadr_microcycle.sv` decides `SRUN`, and both read the level at
    # their own reset arms and nowhere else --- so the records aimed here are
    # in those two files, and the check runs the whole machine because "no
    # microcycle was retired" is a claim about the machine and not about a
    # register.
    "no_auto_boot": {
        "sources": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
        ],
        "extra": [
            "rtl/plumbing/cadr_ddr_map.sv", "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_io_board.sv", "rtl/machine/cadr_busint_regs.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
            "rtl/machine/cadr_dbgin.sv", "rtl/plumbing/cadr_bus_audit.sv",
        ],
        "top": "cadr_machine",
        "tb": "tb/cadr_no_auto_boot_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing",
                  "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": None,
        "gprom": True,
    },

    # LD5, the blue lamp: MIT's `-PROMENABLE` at PCTL 1C19, which the three
    # boards drive their blue lamp from.  A board's top level is reached by
    # lint and by nothing else, so what is held here is the net as
    # `cadr_machine` presents it at its port: up on a fetch, down on a
    # control-store write, and dark for good once `PROMDISABLE` is set.  The
    # records aimed here are the assignment in the processor and the port
    # wiring in `cadr_machine`, which is the one no other check can see.
    "promenable": {
        "sources": [
            "rtl/machine/cadr_microcycle.sv", "rtl/machine/cadr_machine.sv",
        ],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_memory_path.sv",
            "rtl/plumbing/cadr_ddr_map.sv", "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_io_board.sv", "rtl/machine/cadr_busint_regs.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
            "rtl/machine/cadr_dbgin.sv", "rtl/plumbing/cadr_bus_audit.sv",
        ],
        "top": "cadr_machine",
        "tb": "tb/cadr_promenable_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing",
                  "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": None,
        "gprom": True,
    },

    # LD4.  Four lines of fabric in a module of their own, because in the top
    # level they would be reached by the `arty` lint and by nothing else, and
    # lint cannot tell a lamp that latches from one that does not.
    "errhalt_lamp": {
        "sources": ["rtl/plumbing/cadr_lamp_errhalt.sv"],
        "top": "cadr_lamp_errhalt",
        "tb": "tb/cadr_lamp_errhalt_tb.cpp",
        "flags": [],
        "golden": None,
    },

    # LD1 and LD2 on the Arty Z7-20 and LD1's green on the Cora Z7-07S,
    # blinking or steady.  Two modules for LD4's reason --- the top level is
    # reached by lint alone, and lint cannot tell a lamp that follows the MMCM's
    # lock from one that samples it, or a hold re-armed by every microcycle
    # from one that is not --- and one harness that puts them side by side.
    "blink_lamps": {
        "sources": ["rtl/plumbing/cadr_lamp_clock.sv",
                    "rtl/plumbing/cadr_lamp_microcycle.sv"],
        "extra": ["tb/cadr_blink_lamps_harness.sv"],
        "top": "cadr_blink_lamps_harness",
        "tb": "tb/cadr_blink_lamps_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": None,
    },

    "sstep": {
        "sources": ["rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv"],
        "top": "cadr_microcycle",
        "tb": "tb/cadr_sstep_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": "sstep.golden",
        "files": [("boot_prom.hex", "build/boot_prom.hex")],
    },
    "microcycle_sys": {
        "sources": ["rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv"],
        "top": "cadr_microcycle",
        "tb": "tb/cadr_microcycle_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": "rtl_sys.golden",
        "files": [("boot_prom.hex", "build/boot_prom.hex")],
    },
    # THE READ-DURING-WRITE WINDOW OF THE THREE ASYNCHRONOUS MEMORIES, the
    # processor built with `CADR_RDW_POISON` and run on both programs, and the
    # whole machine on `map_access`'s patched PROM, the one program that writes
    # both levels of the map in one write phase.  Under the define, a read of
    # the address written on the most recent edge returns the complement of
    # the word, which is the tick an Altera MLAB leaves undefined; the last
    # section of `rtl/machine/cadr_microcycle.sv` has the argument.  Records
    # aimed here are the ones that put a sampled read into that tick.
    "rdw_poison": {
        "sources": ["rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv"],
        "top": "cadr_microcycle",
        "tb": "tb/cadr_microcycle_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "+define+CADR_RDW_POISON"],
        "golden": "rtl.golden",
        "files": [("boot_prom.hex", "build/boot_prom.hex")],
    },
    "rdw_poison_sys": {
        "sources": ["rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv"],
        "top": "cadr_microcycle",
        "tb": "tb/cadr_microcycle_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "+define+CADR_RDW_POISON"],
        "golden": "rtl_sys.golden",
        "files": [("boot_prom.hex", "build/boot_prom.hex")],
    },
    "rdw_poison_map": {
        "sources": ["rtl/machine/cadr_microcycle.sv", "rtl/plumbing/cadr_ddr_map.sv"],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_io_board.sv", "rtl/machine/cadr_busint_regs.sv",
            "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
            "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
        ],
        "top": "cadr_machine",
        "tb": "tb/cadr_map_access_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "+define+CADR_RDW_POISON", "-Irtl/machine",
                  "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": "rtl.golden",
        "gprom_path": "rdw_poison_map_prom.hex",
    },
    # MD STILL HOLDS WHAT ITS OWN INSTRUCTION PUT THERE.  The same module and
    # the same two programs as the pair above, and a property rather than an
    # agreement: from the `cpu_edge` where DESTMDR writes MD until the write
    # pulse with WMAPD up, nothing may commit a word strobed before that edge.
    # `--public-flat-rw` because DESTMDR, WMAPD, the write pulse and
    # `md_pending` are internal; a testbench re-decoding them out of IR would
    # be checking its own decode.
    "md_hold": {
        "sources": ["rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv"],
        "top": "cadr_microcycle",
        "tb": "tb/cadr_md_hold_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "--public-flat-rw"],
        "golden": "rtl.golden",
        "files": [("boot_prom.hex", "build/boot_prom.hex")],
    },
    "md_hold_sys": {
        "sources": ["rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv"],
        "top": "cadr_microcycle",
        "tb": "tb/cadr_md_hold_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "--public-flat-rw"],
        "golden": "rtl_sys.golden",
        "files": [("boot_prom.hex", "build/boot_prom.hex")],
    },
    # THE ONE TICK NO TRACE REACHES.  A directed stimulus rather than a
    # program: MIT's boot PROM with one extra -LOADMD driven on a DESTMDR
    # boundary, against a control run that drives none.  It was written red,
    # for a defect that was real: `md_pending` survived the edge and the held
    # word committed a boundary later over the instruction's.  The MD
    # register's first branch, a strobe on the boundary's own tick loading MD
    # and clearing the flag, fixed it at 9d1cf26, and the check has passed
    # since and is in `make check`.  `the-destmdr-edge-leaves-a-strobed-word-
    # owed` is the record aimed at it: that branch taken away.
    "md_inject": {
        "sources": ["rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv"],
        "top": "cadr_microcycle",
        "tb": "tb/cadr_md_inject_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "--public-flat-rw"],
        "golden": "rtl.golden",
        "files": [("boot_prom.hex", "build/boot_prom.hex")],
    },
    # The composed machine: the processor with the memory path under it,
    # nothing driven nearer than mem_req/mem_done.  Its own module is pure
    # wiring, which is what makes it the only check that can catch a cable
    # crossed --- both halves are right on their own and the machine is not.
    #
    # `gprom` because this rule passes the PROM image as a parameter with an
    # absolute path rather than leaning on the relative default, as the
    # Makefile does.
    "machine": MACHINE_CHECK,
    # **THE SAME MACHINE CHECK ON QUUX**, and QUUX's programs on both
    # machines.  `machine_quux` is `machine` built with `MACHINE="quux"` and
    # QUUX's boot PROM against muir's trace of that PROM on QUUX; each
    # `quux_<program>` is the whole machine built with a program of
    # `golden/src/quux.rs` as its PROM image, `_quux` on QUUX and without it
    # on the CADR, where it holds the CADR's side of the difference.  `prom`
    # names the PROM image among the goldens, and `machine` says which
    # machine a check holds, which is what `--machine` selects by.
    # QUUX's decode over every address: the feature page and MONO TV's buffer.
    "xbus_decode_quux": {
        "sources": ["rtl/machine/cadr_xbus_decode.sv"],
        "top": "cadr_xbus_decode",
        "tb": "tb/cadr_xbus_decode_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", '-GMACHINE="quux"'],
        "golden": "xbus_decode.quux.golden",
        "machine": "quux",
    },
    "machine_quux": dict(MACHINE_CHECK, **{
        "sources": MACHINE_CHECK["sources"] + QUUX_SOURCES,
        "flags": MACHINE_CHECK["flags"] + ['-GMACHINE="quux"'],
        "golden": "rtl.quux.golden",
        "prom": "boot_prom.quux.hex",
        "machine": "quux",
    }),
    "quux_map": dict(MACHINE_CHECK, **{
        "golden": "quux_map.golden",
        "prom": "quux_map_prom.hex",
    }),
    "quux_map_quux": dict(MACHINE_CHECK, **{
        "sources": MACHINE_CHECK["sources"] + QUUX_SOURCES,
        "flags": MACHINE_CHECK["flags"] + ['-GMACHINE="quux"'],
        "golden": "quux_map.quux.golden",
        "prom": "quux_map_prom.quux.hex",
        "machine": "quux",
    }),
    "quux_tv": dict(MACHINE_CHECK, **{
        "golden": "quux_tv.golden",
        "prom": "quux_tv_prom.hex",
    }),
    "quux_tv_quux": dict(MACHINE_CHECK, **{
        "sources": MACHINE_CHECK["sources"] + QUUX_SOURCES,
        "flags": MACHINE_CHECK["flags"] + ['-GMACHINE="quux"'],
        "golden": "quux_tv.quux.golden",
        "prom": "quux_tv_prom.quux.hex",
        "machine": "quux",
    }),
    "quux_muldiv": dict(MACHINE_CHECK, **{
        "golden": "quux_muldiv.golden",
        "prom": "quux_muldiv_prom.hex",
    }),
    "quux_muldiv_quux": dict(MACHINE_CHECK, **{
        "sources": MACHINE_CHECK["sources"] + QUUX_SOURCES,
        "flags": MACHINE_CHECK["flags"] + ['-GMACHINE="quux"'],
        "golden": "quux_muldiv.quux.golden",
        "prom": "quux_muldiv_prom.quux.hex",
        "machine": "quux",
    }),
    "quux_tick": dict(MACHINE_CHECK, **{
        "golden": "quux_tick.golden",
        "prom": "quux_tick_prom.hex",
    }),
    # QUUX's side of `tick` is `ticksync`, at its synchronous microcycle.
    # Words written into the control store and run, QUUX's alone.
    "quux_imemsync_quux": dict(MACHINE_CHECK, **{
        "sources": MACHINE_CHECK["sources"] + QUUX_SOURCES,
        "flags": MACHINE_CHECK["flags"] + ['-GMACHINE="quux"'],
        "golden": "quux_imemsync.quux.golden",
        "prom": "quux_imemsync_prom.quux.hex",
        "machine": "quux",
    }),
    # A push and a pop, QUUX's alone (`golden/src/quux.rs --program pdlsync`).
    "quux_pdlsync_quux": dict(MACHINE_CHECK, **{
        "sources": MACHINE_CHECK["sources"] + QUUX_SOURCES,
        "flags": MACHINE_CHECK["flags"] + ['-GMACHINE="quux"'],
        "golden": "quux_pdlsync.quux.golden",
        "prom": "quux_pdlsync_prom.quux.hex",
        "machine": "quux",
    }),
    # QUUX's clocks, revision 5 (contract Q1): both timers and the
    # microsecond clock, and the tick's rise at 16.667 ms; the CADR's side
    # of the same program.
    "quux_clocks": dict(MACHINE_CHECK, **{
        "golden": "quux_clocks.golden",
        "prom": "quux_clocks_prom.hex",
    }),
    "quux_clocks_quux": dict(MACHINE_CHECK, **{
        "sources": MACHINE_CHECK["sources"] + QUUX_SOURCES,
        "flags": MACHINE_CHECK["flags"] + ['-GMACHINE="quux"'],
        "golden": "quux_clocks.quux.golden",
        "prom": "quux_clocks_prom.quux.hex",
        "machine": "quux",
    }),
    # The window between a flag's rise and the edge `SINTR` is taken at.
    "quux_tickwin_quux": dict(MACHINE_CHECK, **{
        "sources": MACHINE_CHECK["sources"] + QUUX_SOURCES,
        "flags": MACHINE_CHECK["flags"] + ['-GMACHINE="quux"'],
        "golden": "quux_tickwin.quux.golden",
        "prom": "quux_tickwin_prom.quux.hex",
        "machine": "quux",
    }),
    # The clocks read between the edges, and in a held microcycle.
    "quux_clockwait_quux": dict(MACHINE_CHECK, **{
        "sources": MACHINE_CHECK["sources"] + QUUX_SOURCES,
        "flags": MACHINE_CHECK["flags"] + ['-GMACHINE="quux"'],
        "golden": "quux_clockwait.quux.golden",
        "prom": "quux_clockwait_prom.quux.hex",
        "machine": "quux",
    }),
    # QUUX's register page, keyboard, network and no Unibus (Q2 to Q5).
    "quux_page_quux": dict(MACHINE_CHECK, **{
        "sources": MACHINE_CHECK["sources"] + QUUX_SOURCES,
        "flags": MACHINE_CHECK["flags"] + ['-GMACHINE="quux"'],
        "golden": "quux_page.quux.golden",
        "prom": "quux_page_prom.quux.hex",
        "machine": "quux",
    }),
    "quux_divmd": dict(MACHINE_CHECK, **{
        "golden": "quux_divmd.golden",
        "prom": "quux_divmd_prom.hex",
    }),
    "quux_divmd_quux": dict(MACHINE_CHECK, **{
        "sources": MACHINE_CHECK["sources"] + QUUX_SOURCES,
        "flags": MACHINE_CHECK["flags"] + ['-GMACHINE="quux"'],
        "golden": "quux_divmd.quux.golden",
        "prom": "quux_divmd_prom.quux.hex",
        "machine": "quux",
    }),
    "quux_tickwait": dict(MACHINE_CHECK, **{
        "golden": "quux_tickwait.golden",
        "prom": "quux_tickwait_prom.hex",
    }),
    # QUUX's keyboard and mouse on their own, against `QuuxInput`.
    "quux_input_quux": {
        "sources": ["rtl/machine/quux_input.sv"],
        "top": "quux_input",
        "tb": "tb/quux_input_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": "quux_input.quux.golden",
        "machine": "quux",
    },
    # QUUX's block-disk on its own, against `BlockDisk`.
    "quux_block_disk_quux": {
        "sources": ["rtl/machine/quux_block_disk.sv"],
        "top": "quux_block_disk",
        "tb": "tb/quux_block_disk_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": "quux_block_disk.quux.golden",
        "machine": "quux",
    },
    # QUUX's multiply and divide on their own, against `muldiv::run`.
    "muldiv_quux": {
        "sources": ["rtl/machine/quux_muldiv.sv"],
        "top": "quux_muldiv",
        "tb": "tb/quux_muldiv_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": "muldiv.quux.golden",
        "machine": "quux",
    },
    # EVERY FREE-RUNNING CLOCK OF THE COMPOSED MACHINE AGAINST muir, from the
    # processor's origin: the I/O board's clocks and the display's program from
    # power-on, each held to muir's instants under the fabric's timing model.
    # The records aimed here are the ones about WHERE a clock starts, which the
    # card's and the display's own checks cannot see, each setting muir's
    # t = 0 from its own reset.  Built with `--public-flat-rw`, the clocks
    # reaching no port; everything with a check of its own is in `extra`.
    "power_on": {
        "sources": [
            "rtl/machine/cadr_io_board.sv", "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_busint_xbus.sv",
        ],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/plumbing/cadr_ddr_map.sv", "rtl/machine/cadr_xbus_decode.sv",
            "rtl/plumbing/cadr_xbus_ddr.sv", "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_busint_regs.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
            "rtl/machine/cadr_dbgin.sv", "rtl/plumbing/cadr_bus_audit.sv",
            "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
        ],
        "top": "cadr_machine",
        "tb": "tb/cadr_power_on_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "--public-flat-rw", "-Irtl/machine",
                  "-Irtl/plumbing", "-Irtl/plumbing/xilinx7",
                  "-Iboards/arty-z7-20"],
        "golden": "power_on.golden",
        "gprom": True,
    },
    # The machine behind real memory, which is what `DDR=1` puts on the part.
    # Same module list as `machine` and a different question: `machine` asks
    # whether the fabric agrees with muir, and this asks what it does where
    # muir cannot follow it --- past microcycle 537,900, where muir's modeled
    # disk controller answers the boot PROM's polls and the board's does not
    # exist.  Its reference is the boot PROM's own page-0 parity loop with a
    # poison in it and a modeled DDR3 that answers at a delay of its own.
    #
    # No `golden`: there is no trace to hand it.  The testbench runs the
    # machine twice from reset, 200 ms of machine time each way, and takes
    # about fifteen seconds --- the slowest check here that is not a trace.
    # CAN THE COMPOSED MACHINE LEAVE MD STALE ACROSS A READ?  `md_hold` and
    # `md_inject` ask that of `cadr_microcycle`, where the bus is muir's
    # stimulus; this asks it of the whole machine with only DDR modeled, and
    # it answers the open question of whether the DESTMDR/-LOADMD coincidence
    # can be placed at all.  It also compares the direction of every DDR
    # transaction against the processor's own WRCYC, which nothing else in
    # `make check` does.
    #
    # No `golden`: there is no trace to hand it.  Everything with a check of
    # its own is in `extra`.
    "md_compose": {
        "sources": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/plumbing/cadr_ddr_map.sv", "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
        ],
        "extra": [
            "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_io_board.sv", "rtl/machine/cadr_busint_regs.sv",
            "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
        ],
        "top": "cadr_machine",
        "tb": "tb/cadr_md_compose_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "--public-flat-rw", "-Irtl/machine",
                  "-Irtl/plumbing", "-Irtl/plumbing/xilinx7",
                  "-Iboards/arty-z7-20"],
        "golden": None,
        "gprom": True,
    },
    # WRITES AGAINST THE READS BESIDE THEM: muir's own
    # `tests/dispatch_write_order.rs` programs, run on the whole machine and
    # held to `rtl` every microcycle and every word of the end state.  The
    # programs and the memories they start from are loaded into the fabric's
    # arrays, hence `--public-flat-rw`.  Records aimed here are the ones about
    # which write pulse fires, when it takes its address, and which VMA the
    # bus address takes its low byte from.
    "dispatch_write_order": {
        # The bus interface is named because the edge-tie programs hold its
        # acknowledgment instants: the NXM timer's, and `-UB MSYN`'s through
        # the mode-register writes.
        "sources": ["rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
                    "rtl/machine/cadr_spy_registers.sv", "rtl/machine/cadr_busint_xbus.sv"],
        "extra": [
            "rtl/plumbing/cadr_ddr_map.sv", "rtl/machine/cadr_xbus_decode.sv",
            "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_disk_controller.sv",
            "rtl/machine/cadr_tv.sv", "rtl/machine/cadr_io_board.sv",
            "rtl/machine/cadr_busint_regs.sv", "rtl/machine/cadr_console_bus.sv",
            "rtl/machine/cadr_console_state.sv", "rtl/machine/cadr_dbgin.sv",
            "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
        ],
        "top": "cadr_machine",
        "tb": "tb/cadr_dispatch_write_order_tb.cpp",
        # With the gap monitor, which is what catches a write placed a tick
        # too near MD or the boundary with the word still right.
        "flags": ["-O2", "-CFLAGS", "-O2", "+define+CADR_GAP_MONITOR",
                  "-CFLAGS", "-DCADR_GAP_MONITOR", "--public-flat-rw", "-Irtl/machine",
                  "-Irtl/plumbing", "-Irtl/plumbing/xilinx7",
                  "-Iboards/arty-z7-20"],
        "golden": "dispatch_write_order.golden",
        "gprom": True,
    },
    # A HALTED MACHINE MUST GO ON MAKING MASTER CLOCKS.  `Rtl::step` answers
    # a halted machine before it looks at the bus at all, so muir never takes
    # a `-HANG` there; this is that property on the composed machine, where a
    # memory cycle can actually be outstanding while the clock is stopped.
    # The files it holds are the four the ring and its stops live in ---
    # the generator, the processor, the bus interface --- and the two the
    # console reaches them through.
    "park": {
        "sources": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/machine/cadr_busint_xbus.sv",
            "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_console_bus.sv",
        ],
        "extra": [
            "rtl/plumbing/cadr_ddr_map.sv", "rtl/machine/cadr_xbus_decode.sv",
            "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_io_board.sv", "rtl/machine/cadr_busint_regs.sv",
            "rtl/machine/cadr_console_state.sv", "rtl/machine/cadr_dbgin.sv",
            "rtl/plumbing/cadr_bus_audit.sv",
            "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
        ],
        "top": "cadr_machine",
        "tb": "tb/cadr_park_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "+define+CADR_GAP_MONITOR", "--public-flat-rw", "-Irtl/machine",
                  "-Irtl/plumbing", "-Irtl/plumbing/xilinx7",
                  "-Iboards/arty-z7-20"],
        "golden": None,
        "gprom": True,
    },
    "ddr_boot": {
        "sources": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/plumbing/cadr_ddr_map.sv", "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
        ],
        "extra": ["rtl/machine/cadr_console_state.sv"],
        "top": "cadr_machine",
        "tb": "tb/cadr_ddr_boot_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "+define+CADR_GAP_MONITOR", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": None,
        "gprom": True,
    },
    # THE BOOT LINES, ON THE WHOLE MACHINE.  `iob` holds the card's own
    # decode of the keyboard's boot word against muir --- which eight bits
    # the 25LS2521 at IOBCSR 0A20 compares, and how wide a pulse a match
    # makes --- and says nothing about what the pulse then reaches.  This is
    # the other half: `cadr_machine` running MIT's boot PROM, a word at the
    # keyboard's cable, and the PROM running from word 0 again.  muir's
    # `tests/keyboard_boot.rs` is the same claim on `micro`, `rtl` and
    # `chip`.  `cadr_io_board.sv` is in `sources` here as well as in `iob`'s,
    # because a record aimed at the decode has to be able to ask which of the
    # two checks sees it.
    "kbd_boot": {
        "sources": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/machine/cadr_io_board.sv", "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
        ],
        # Everything else `cadr_machine` is built out of, each with checks of
        # its own.  `cadr_ddr_map.sv` is a PACKAGE and has to be named: the
        # include path finds a module by its file name and does not find a
        # package that way.
        "extra": [
            "rtl/plumbing/cadr_ddr_map.sv", "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
        ],
        "top": "cadr_machine",
        "tb": "tb/cadr_kbd_boot_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": None,
        "gprom": True,
    },
    # THE MAP, WRITTEN AND THEN READ THROUGH, AGAINST A REAL MEMORY.  Same
    # module list and same reference as `machine`, and one thing different:
    # there `mem_rdata` is muir's own MD column keyed by the ROW, so the word
    # is right whatever address the map produced and a mistranslation is
    # invisible; here it is fetched from a store keyed by `mem_addr`, with
    # page 0 holding what muir's memory holds and every other address holding
    # a poison injective in it.  `ddr_boot` is the same claim from the other
    # side and cannot make it either, having no muir reference at all.
    #
    # `sources` is the two files a map fault can live in --- the map itself in
    # `cadr_microcycle.sv`, and `cadr_ddr_map::main_byte_address`, the last
    # step from the physical word to the byte address on `mem_*` --- and the
    # rest of the machine is `extra`, having `machine`'s own records aimed at
    # it.  A record aimed here should be run against `machine` too and the
    # difference reported: a mutation both catch says nothing new, and one
    # only this catches is the hole it was written for.  Measured at this
    # slice: four of the five are caught both ways and
    # `the-memory-address-loses-its-page-bit` is caught only here.
    "map_boot": {
        "sources": ["rtl/machine/cadr_microcycle.sv", "rtl/plumbing/cadr_ddr_map.sv"],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
            "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
        ],
        "top": "cadr_machine",
        "tb": "tb/cadr_map_boot_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": "rtl.golden",
        "gprom": True,
    },
    # The map's two access bits told apart, which `map_boot` cannot do: muir
    # refuses the access on 0 of its 600,000 microcycles and every map word the
    # boot PROM writes has bits 23 and 22 alike, so `-VMAOK` was only ever
    # compared in its permitted direction.  This check moves one field of one
    # microinstruction of MIT's own PROM so that the same program writes
    # `MAP-ACCESS-CODE` 3, 2 and 0, and runs it four times.
    #
    # `gprom_path` rather than `gprom`: the testbench WRITES its patched image
    # before the model reads it, so it must have a file of its own, and that
    # file belongs in the mutant's own work directory.  Sharing one would be
    # the stale-artifact family this file's neighbors keep meeting --- every
    # mutant writing one path, and a later run reading an earlier one's PROM.
    # Everything else is `map_boot`'s entry.
    "map_access": {
        "sources": ["rtl/machine/cadr_microcycle.sv", "rtl/plumbing/cadr_ddr_map.sv"],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_io_board.sv", "rtl/machine/cadr_busint_regs.sv",
            "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
            "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
        ],
        "top": "cadr_machine",
        "tb": "tb/cadr_map_access_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing",
                  "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": "rtl.golden",
        "gprom_path": "map_access_prom.hex",
    },
    # The memory port's tally, which is the board's only positive witness that
    # the machine's memory cycles were ANSWERED.  The boot PROM's traffic is an
    # identity copy, so page 0 reading back unchanged says the same thing
    # whether the port answered or was never brought up, and no lamp tells them
    # apart either --- so these four numbers are what step four is read by, and
    # an instrument nothing checks is worse than no instrument.
    #
    # `sources` is the counter alone: the machine, the bridge, the adapter and
    # the widening are in `extra`, having checks of their own, and
    # `tb/cadr_mem_count_harness.sv` is the wiring rather than the thing
    # checked.  The testbench runs two configurations --- the port answering
    # and the port held in reset --- and the second is what a mutation that
    # counted the fabric's own intentions falls over.
    "mem_count": {
        "sources": ["rtl/plumbing/cadr_mem_count.sv"],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/plumbing/cadr_ddr_map.sv", "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_spy_registers.sv", "rtl/machine/cadr_disk_controller.sv",
            "rtl/machine/cadr_tv.sv", "rtl/machine/cadr_console_bus.sv",
            "rtl/machine/cadr_console_state.sv", "rtl/machine/cadr_memory_path.sv",
            "rtl/machine/cadr_machine.sv", "rtl/plumbing/cadr_axi_master.sv",
            "rtl/plumbing/cadr_axi_widen.sv", "tb/cadr_mem_count_harness.sv",
        ],
        "top": "cadr_mem_count_harness",
        "tb": "tb/cadr_mem_count_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": None,
        "gprom": True,
    },
    # THE MACHINE ON THE DE25-NANO'S MEMORY PORT, which is one port with three
    # masters on it and a gate software opens.  `sources` is the arbiter, the
    # gate, the port that wires them and the map the board's addresses come
    # from; the machine, the adapter, the widening and the tally are `extra`,
    # having checks of their own, and `tb/cadr_f2sdram_harness.sv` is the
    # wiring rather than the thing checked.
    #
    # **BUILT WITH THE DE25-NANO'S MAP**, as the Makefile builds it: the
    # addresses the machine puts on the bridge are the board's, and the model
    # behind the bridge watches those.
    #
    # Five configurations, and each catches what the others cannot: the port
    # open, the port never opened, the same machine cycles with and without
    # two other masters streaming, and the processor asking the fabric to be
    # quiet in the middle of the loop.  `tb/cadr_f2sdram_tb.cpp`'s header has
    # them and the bound.
    "f2sdram": {
        "sources": ["rtl/plumbing/cadr_ddr_map.sv",
                    "rtl/plumbing/cadr_f2sdram_gate.sv",
                    "rtl/plumbing/cadr_f2sdram_share.sv",
                    "rtl/plumbing/cadr_f2sdram_port.sv"],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_spy_registers.sv", "rtl/machine/cadr_disk_controller.sv",
            "rtl/machine/cadr_tv.sv", "rtl/machine/cadr_io_board.sv",
            "rtl/machine/cadr_busint_regs.sv", "rtl/machine/cadr_console_bus.sv",
            "rtl/machine/cadr_console_state.sv", "rtl/machine/cadr_dbgin.sv",
            "rtl/plumbing/cadr_bus_audit.sv", "rtl/machine/cadr_memory_path.sv",
            "rtl/machine/cadr_machine.sv", "rtl/plumbing/cadr_axi_master.sv",
            "rtl/plumbing/cadr_axi_widen.sv", "rtl/plumbing/cadr_mem_count.sv",
            "tb/cadr_f2sdram_harness.sv",
        ],
        "top": "cadr_f2sdram_harness",
        "tb": "tb/cadr_f2sdram_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-DCADR_DDR_MAP_DE25_NANO",
                  "-Irtl/machine", "-Irtl/plumbing"],
        "golden": None,
        "gprom": True,
    },
    # THE PORT'S TWO RESETS WITH TRANSACTIONS IN FLIGHT, the second half of
    # `build/f2sdram.pass`: the machine's side of the port driven directly, the
    # fabric's reset pulsed under a read, a write and the pack side's burst,
    # and the processor's reset raised under a read the bridge drops.  The
    # machine is not in it, so it is seconds where `f2sdram` is minutes, and a
    # record aimed at the gate's two resets belongs here.
    "f2sdram_reset": {
        "sources": ["rtl/plumbing/cadr_f2sdram_gate.sv",
                    "rtl/plumbing/cadr_f2sdram_share.sv",
                    "rtl/plumbing/cadr_f2sdram_port.sv"],
        "extra": ["rtl/plumbing/cadr_axi_master.sv", "rtl/plumbing/cadr_axi_widen.sv",
                  "rtl/plumbing/cadr_mem_count.sv"],
        "top": "cadr_f2sdram_port",
        "tb": "tb/cadr_f2sdram_reset_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/plumbing"],
        "golden": None,
    },
    # AND THE DEFAULT SLAVE AT THE AGILEX 5 BRIDGES' SHAPE, four bits of ID
    # and eight of read length: the same module and the same testbench, built
    # as `build/gp0_default.pass` builds it a second time.  A record aimed at
    # what only a burst longer than sixteen beats can reach belongs here, and
    # one aimed at the module's shape belongs at `gp0_default` above, where it
    # is the same speed and says the same thing.
    "gp0_default_axi4": {
        "sources": ["rtl/plumbing/cadr_gp0_default.sv"],
        "top": "cadr_gp0_default",
        "tb": "tb/cadr_gp0_default_tb.cpp",
        "flags": ["-GID_W=4", "-GLEN_W=8", "-CFLAGS", "-DGP_ID_W=4",
                  "-CFLAGS", "-DGP_LEN_W=8"],
        "golden": None,
    },
    # ONE TRANSACTION PER BUS CYCLE, IN THE DIRECTION WRCYC NAMES, AND NONE
    # ANYWHERE ELSE.  The property a spurious write at a read's own address
    # falls over, which is the shape the board's page-hash-table corruption has
    # been narrowed to.  `axi_master` is one level down and cannot see it --- a
    # check whose stimulus IS the transactions cannot count how many a bus
    # cycle issued --- and `mem_count` holds the run's totals to 256 and 256,
    # which is the boot PROM's arithmetic and not a property.
    #
    # `sources` is the three modules a spurious transaction can be born in:
    # the bridge that raises `mem_req`, the adapter that turns it into AXI, and
    # the memory path that decides which cycles reach the bridge at all.  The
    # rest of the machine is `extra`, having `machine`'s own records aimed at
    # it, and `tb/cadr_bus_audit_harness.sv` is the wiring rather than the
    # thing checked.
    #
    # A record aimed here should be run against `axi_master`, `ddr_boot`,
    # `machine` and `mem_count` too and the difference reported: a mutation
    # they all catch says nothing new, and one only this catches is the hole it
    # was written for.
    # `cadr_ddr_map.sv` heads `sources` for the reason `memory_path`'s and
    # `map_boot`'s entries put it there: Verilator reads the files in the
    # order it is given them and a package has to be declared before the
    # module that imports it, and `sources` is passed before `extra`.  It is
    # not what these records are aimed at; `map_boot`'s are.
    # `cadr_machine.sv` JOINED `sources` WHEN THE AUDIT WAS WIRED IN.  The
    # owner bundle the instrument is anchored on --- whose cycle is open, its
    # direction, its held decode --- is written there, and a record aimed at it
    # has to name a check that BUILDS it in `sources` rather than in `extra`.
    # This is the check whose business that bundle is: it is the one that runs
    # the whole path against a real program.
    "bus_audit": {
        "sources": [
            "rtl/plumbing/cadr_ddr_map.sv",
            "rtl/plumbing/cadr_xbus_ddr.sv", "rtl/plumbing/cadr_axi_master.sv",
            "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
        ],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv",
            "rtl/machine/cadr_spy_registers.sv", "rtl/machine/cadr_disk_controller.sv",
            "rtl/machine/cadr_tv.sv", "rtl/machine/cadr_io_board.sv",
            "rtl/machine/cadr_busint_regs.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
            "rtl/plumbing/cadr_bus_audit.sv", "rtl/plumbing/cadr_axi_widen.sv",
            "tb/cadr_bus_audit_harness.sv",
        ],
        "top": "cadr_bus_audit_harness",
        "tb": "tb/cadr_bus_audit_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": None,
        "gprom": True,
    },
    # A PACK BLOCK INTO MAIN MEMORY THROUGH THE ADAPTER AND THE WIDENING.
    # `bus_audit` above is MIT's boot PROM with no drive on the cable --- 512
    # identity memory cycles and no channel at all, its own testbench asserting
    # that the disk channel never took the bus.  This is the same three modules
    # with a DRIVE on the cable and a synthetic pack behind the block store's
    # seam, so the second Xbus master crosses the widening 256 words a page and
    # the machine reads back through it what the channel wrote.
    #
    # The pack is generated a block at a time and its words are poison
    # injective in the disk address AND DECODABLE, so a page of main memory is
    # read back and decoded rather than compared against a shadow.  Nothing is
    # copied into the mutant's work directory: there is no file.
    "axi_channel": {
        # THE ORDER IS THE MAKEFILE'S, because `cadr_ddr_map` is a package and
        # `cadr_xbus_ddr` reads it: verilated out of order it is PKGNODECL.
        "sources": [
            "rtl/plumbing/cadr_ddr_map.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/plumbing/cadr_axi_master.sv", "rtl/plumbing/cadr_axi_widen.sv",
            "rtl/machine/cadr_memory_path.sv",
        ],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv",
            "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_disk_controller.sv",
            "rtl/machine/cadr_tv.sv", "rtl/machine/cadr_io_board.sv",
            "rtl/machine/cadr_busint_regs.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
            "rtl/machine/cadr_machine.sv",
            "tb/cadr_band_axi_harness.sv",
        ],
        "top": "cadr_band_axi_harness",
        "tb": "tb/cadr_axi_channel_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing",
                  "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": None,
        "gprom": True,
    },
    # THE SAME COMPOSITION WITH THE PACK SIDE IN IT.  `axi_channel` above runs
    # the boot PROM with a drive on the cable and a pack behind the block
    # store's seam --- but its feeder IS the testbench, writing 259 words into
    # a slot a word at a time.  `rtl/plumbing/cadr_disk_pack.sv`, its
    # `S_AXI_HP2` master and its `M_AXI_GP0` register face had never been
    # instantiated in a whole-machine check anywhere in this tree, so this is
    # the same eight clauses with one more module and two more ports under
    # them, plus four of its own.  Nothing is copied into the mutant's work
    # directory: the pack is generated a block at a time and there is no file.
    #
    # `sources` is the pack side ALONE.  Everything below it has `axi_channel`
    # aimed at it already, and a record aimed at two checks would be caught
    # twice and say nothing new the second time.
    # THE BLOCK STORE IN ITS UNDEFINED TICK.  On the DE25-Nano the store is an
    # M20K with read-during-write checking off, so the word either port reads
    # in the tick after an edge that wrote the array is not specified; the
    # poison returns the complement there and this is `pack_channel`'s own run
    # with it on.  A record aimed at the poison belongs here, where it is the
    # thing being exercised; one aimed at the store's logic belongs at
    # `pack_channel`, where it is the same stimulus and runs faster.
    "rdw_poison_disk": {
        "sources": ["rtl/machine/cadr_disk_controller.sv"],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/plumbing/cadr_ddr_map.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv",
            "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_tv.sv", "rtl/machine/cadr_io_board.sv",
            "rtl/machine/cadr_busint_regs.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
            "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
            "rtl/plumbing/cadr_axi_master.sv", "rtl/plumbing/cadr_axi_widen.sv",
            "rtl/plumbing/cadr_disk_pack.sv",
            "tb/cadr_pack_axi_harness.sv",
        ],
        "top": "cadr_pack_axi_harness",
        "tb": "tb/cadr_pack_channel_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "+define+CADR_RDW_POISON_DISK",
                  "-Irtl/machine", "-Irtl/plumbing",
                  "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": None,
        "gprom": True,
    },
    "pack_channel": {
        "sources": ["rtl/plumbing/cadr_disk_pack.sv"],
        # THE ORDER IS THE MAKEFILE'S, because `cadr_ddr_map` is a package and
        # `cadr_xbus_ddr` reads it: verilated out of order it is PKGNODECL.
        "extra": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/plumbing/cadr_ddr_map.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv",
            "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_disk_controller.sv",
            "rtl/machine/cadr_tv.sv", "rtl/machine/cadr_io_board.sv",
            "rtl/machine/cadr_busint_regs.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
            "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
            "rtl/plumbing/cadr_axi_master.sv", "rtl/plumbing/cadr_axi_widen.sv",
            "tb/cadr_pack_axi_harness.sv",
        ],
        "top": "cadr_pack_axi_harness",
        "tb": "tb/cadr_pack_channel_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing",
                  "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": None,
        "gprom": True,
    },
    # THE SAME PROPERTY IN FABRIC, and the same name for it on purpose: the
    # check above holds it for the one program `cadr_machine` can run under
    # Verilator, and `rtl/plumbing/cadr_bus_audit.sv` carries it onto the board
    # for the program the board runs.  Two implementations of one concept, so
    # one term: the same concept takes the same term, always.
    #
    # The DUT is the module alone and the stimulus is directed.  That is not a
    # smaller version of the check above; it is the only way the clauses
    # themselves get exercised at all, a program not being something you can
    # make fault on demand.
    "bus_audit_unit": {
        "sources": ["rtl/plumbing/cadr_bus_audit.sv"],
        "top": "cadr_bus_audit",
        "tb": "tb/cadr_bus_audit_unit_tb.cpp",
        "flags": [],
        "golden": None,
    },
    # THE JOIN: the audit on the console's readout window, which is how a board
    # is asked about it hours after it has stopped.  `bus_audit_unit` holds the
    # module, `bus_audit` holds the property through the composed machine and
    # `readout` holds the window against the processor's arrays; NOTHING held
    # the three wires between them until this check, and a mux on
    # `con_ro_data` that selected the wrong arm, a `sel` off by a tick or a
    # selector that swallowed its neighbors would each have been silent.
    #
    # `sources` is the two files the join is written in.  The rest of the
    # machine is `extra`, having its own checks' records aimed at it, and
    # `cadr_ddr_map.sv` heads the list for the reason `memory_path`'s entry
    # puts it there: a package has to be declared before the module that
    # imports it and `sources` is passed before `extra`.
    "audit_window": {
        "sources": [
            "rtl/plumbing/cadr_ddr_map.sv",
            "rtl/plumbing/cadr_bus_audit.sv",
            "rtl/machine/cadr_machine.sv",
        ],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_io_board.sv", "rtl/machine/cadr_busint_regs.sv",
            "rtl/machine/cadr_console_bus.sv",
            "rtl/machine/cadr_console_state.sv",
            "rtl/machine/cadr_memory_path.sv",
        ],
        "top": "cadr_machine",
        "tb": "tb/cadr_audit_window_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "--public-flat-rw", "-Irtl/machine",
                  "-Irtl/plumbing", "-Irtl/plumbing/xilinx7",
                  "-Iboards/arty-z7-20"],
        "golden": None,
        "gprom": True,
    },
    # The probe the board will be read through. `tb/cadr_probe_harness.sv`
    # wires it to `cadr_machine` exactly as `boards/arty-z7-20/cadr_arty.sv` does and the
    # testbench shifts all 1,024 samples out through the probe's own JTAG shift
    # register, so what these mutations are aimed at is an instrument whose
    # only other verification is a board nobody has run it on yet.
    "probe": {
        "sources": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/plumbing/cadr_ddr_map.sv", "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
            "rtl/plumbing/cadr_probe.sv", "rtl/plumbing/agilex5/cadr_probe_vjtag.sv",
            "tb/cadr_probe_harness.sv",
        ],
        "extra": ["rtl/machine/cadr_console_state.sv"],
        "top": "cadr_probe_harness",
        "tb": "tb/cadr_probe_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": "rtl.golden",
        "gprom": True,
    },
    # The OTHER half of the probe, and the only check here of something that
    # is not fabric at all.  `boards/arty-z7-20/vivado/probe.tcl` reads the capture off the board
    # over JTAG; `tb/cadr_probe_jtag_tb.tcl` runs it against a shift-chain
    # model in `tb/cadr_jtag_chain.tcl`, on seven chains, with no board and no
    # Vivado.
    #
    # `kind: tcl` means the check is `tclsh <tb>`: the harness exiting non-zero
    # is the mutation being caught.  There is no build step and so no BROKEN
    # verdict --- Tcl compiles nothing, and a mutation that is not valid Tcl
    # fails at the line that runs it, which the harness reports as the case
    # failing.  That is the one way this differs from every other check here,
    # and it is why `--self-test` skips this kind when it wants a check that
    # can be made not to build.
    #
    # `sources` is the script and `tools/jtag_target.tcl`, which `probe.tcl`
    # sources to pick a JTAG target by cable serial rather than by position:
    # a mutation of that helper is a mutation of what runs, the same as one
    # of the script itself.  The model and the harness are the check, not the
    # thing checked, and mutating them would be mutating a testbench.
    "probe_jtag": {
        "kind": "tcl",
        "sources": ["boards/arty-z7-20/vivado/probe.tcl",
                    "tools/jtag_target.tcl"],
        "tb": "tb/cadr_probe_jtag_tb.tcl",
        "golden": None,
    },
    # The DE25-Nano's two JTAG scripts, the probe's reader and the USERCODE
    # read-back `program.sh` runs, against `tb/cadr_de25_jtag_model.tcl`: the
    # `quartus_stp` commands they use, with the shapes measured on the board.
    # `jtag.tcl` is what both source; the model and the harness are the check.
    "de25_jtag": {
        "kind": "tcl",
        "sources": ["boards/de25-nano/quartus/probe.tcl",
                    "boards/de25-nano/quartus/jtag.tcl",
                    "boards/de25-nano/quartus/usercode.tcl"],
        "tb": "tb/cadr_de25_jtag_tb.tcl",
        "golden": None,
    },
    # The two programming scripts, against a stubbed hardware manager.
    # `tools/build_stamp.tcl` is this script's own; `tools/jtag_target.tcl`
    # is also `probe.tcl`'s, above.  A record aims at each source here, which
    # is what `check_coverage` asks for and what keeps a shared file from
    # being the one nothing tests.
    "program_tcl": {
        "kind": "tcl",
        "sources": ["boards/arty-z7-20/vivado/program.tcl",
                    "tools/build_stamp.tcl", "tools/jtag_target.tcl"],
        "tb": "tb/cadr_program_tb.tcl",
        "golden": None,
    },
    # The top level, and the only check that is lint alone: Verilator has no
    # `MMCME2_BASE`, so `cadr_arty` cannot be simulated. What lint holds is
    # the port list and the `witness` fold --- an output left off the
    # instantiation is a PINMISSING, one left out of the fold is an
    # UNUSEDSIGNAL. `extra` rather than `sources` for everything below the top
    # level, because `check_coverage` asks that every source a check builds has
    # a mutation aimed at it and only cadr_arty.sv does.
    # THE FABRIC'S RESET UNDER THE PROCESSOR'S TRANSACTIONS, on each board's
    # own top level: `build/board_reset.pass`, three builds, one a board.  The
    # only checks that simulate a top level, so a record aimed at which reset
    # a top level gives which module belongs here, and so does one aimed at a
    # face's split between the port's reset and the fabric's: no module check
    # raises the fabric's reset under traffic.  `tb/cadr_board_reset_tb.cpp`
    # says what each holds.  The package with the processor's DPI goes first,
    # as `cadr_tick_pkg.sv` does, because the models import it.
    "board_reset_arty": {
        "sources": ["rtl/plumbing/cadr_ddr_map.sv", "boards/arty-z7-20/cadr_arty.sv",
                    "rtl/plumbing/cadr_display_out.sv",
                    "rtl/plumbing/cadr_gp0_split.sv", "rtl/plumbing/cadr_gp1_split.sv",
                    "rtl/plumbing/cadr_gp0_default.sv", "rtl/plumbing/cadr_disk_pack.sv",
                    "rtl/plumbing/cadr_chaos_cable.sv", "rtl/plumbing/cadr_serial_line.sv",
                    "rtl/plumbing/cadr_input_cables.sv", "rtl/plumbing/cadr_console.sv",
                    "rtl/plumbing/cadr_debug_window.sv"],
        "extra": ["tb/cadr_sim_axi.sv", "tb/cadr_ps7_sim.sv",
                  "tb/cadr_arty_stubs.sv", "tb/cadr_usr_access_stub.sv",
                  "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
                  "rtl/machine/cadr_xbus_decode.sv",
                  "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
                  "rtl/machine/cadr_spy_registers.sv", "rtl/machine/cadr_disk_controller.sv",
                  "rtl/machine/cadr_tv.sv", "rtl/machine/cadr_io_board.sv",
                  "rtl/machine/cadr_busint_regs.sv", "rtl/machine/cadr_console_bus.sv",
                  "rtl/machine/cadr_console_state.sv", "rtl/machine/cadr_dbgin.sv",
                  "rtl/plumbing/cadr_bus_audit.sv", "rtl/machine/cadr_memory_path.sv",
                  "rtl/machine/cadr_machine.sv",
                  "rtl/plumbing/cadr_dbg_tx.sv", "rtl/plumbing/cadr_dbg_rx.sv",
                  "rtl/plumbing/cadr_dbg_join.sv", "rtl/plumbing/cadr_dbg_cable.sv",
                  "rtl/plumbing/cadr_lamp_errhalt.sv", "rtl/plumbing/cadr_lamp_clock.sv",
                  "rtl/plumbing/cadr_lamp_microcycle.sv",
                  "rtl/plumbing/cadr_axi_master.sv", "rtl/plumbing/cadr_axi_widen.sv",
                  "rtl/plumbing/cadr_mem_count.sv", "rtl/plumbing/cadr_gp_regs.sv",
                  "rtl/plumbing/cadr_tmds_encode.sv", "rtl/plumbing/cadr_hdmi_tx.sv",
                  "rtl/plumbing/xilinx7/cadr_hdmi_phy.sv",
                  "tb/cadr_board_reset_harness.sv"],
        "top": "cadr_board_reset_harness",
        "tb": "tb/cadr_board_reset_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Wno-PINCONNECTEMPTY",
                  "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7",
                  "-DCADR_BOARD_ARTY", "-CFLAGS", "-DCADR_BOARD_ARTY"],
        "golden": None,
        "gprom": True,
    },
    "board_reset_cora": {
        "sources": ["rtl/plumbing/cadr_ddr_map.sv", "boards/cora-z7-07s/cadr_cora.sv",
                    "rtl/plumbing/cadr_gp0_split.sv", "rtl/plumbing/cadr_gp1_split.sv",
                    "rtl/plumbing/cadr_gp0_default.sv", "rtl/plumbing/cadr_disk_pack.sv",
                    "rtl/plumbing/cadr_chaos_cable.sv", "rtl/plumbing/cadr_serial_line.sv",
                    "rtl/plumbing/cadr_input_cables.sv", "rtl/plumbing/cadr_console.sv",
                    "rtl/plumbing/cadr_debug_window.sv"],
        "extra": ["tb/cadr_sim_axi.sv", "tb/cadr_ps7_sim.sv",
                  "tb/cadr_arty_stubs.sv", "tb/cadr_usr_access_stub.sv",
                  "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
                  "rtl/machine/cadr_xbus_decode.sv",
                  "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
                  "rtl/machine/cadr_spy_registers.sv", "rtl/machine/cadr_disk_controller.sv",
                  "rtl/machine/cadr_tv.sv", "rtl/machine/cadr_io_board.sv",
                  "rtl/machine/cadr_busint_regs.sv", "rtl/machine/cadr_console_bus.sv",
                  "rtl/machine/cadr_console_state.sv", "rtl/machine/cadr_dbgin.sv",
                  "rtl/plumbing/cadr_bus_audit.sv", "rtl/machine/cadr_memory_path.sv",
                  "rtl/machine/cadr_machine.sv",
                  "rtl/plumbing/cadr_dbg_tx.sv", "rtl/plumbing/cadr_dbg_rx.sv",
                  "rtl/plumbing/cadr_dbg_join.sv", "rtl/plumbing/cadr_dbg_cable.sv",
                  "rtl/plumbing/cadr_lamp_errhalt.sv", "rtl/plumbing/cadr_lamp_clock.sv",
                  "rtl/plumbing/cadr_lamp_microcycle.sv",
                  "rtl/plumbing/cadr_axi_master.sv", "rtl/plumbing/cadr_axi_widen.sv",
                  "rtl/plumbing/cadr_mem_count.sv", "rtl/plumbing/cadr_gp_regs.sv",
                  "tb/cadr_board_reset_harness.sv"],
        "top": "cadr_board_reset_harness",
        "tb": "tb/cadr_board_reset_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Wno-PINCONNECTEMPTY",
                  "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7",
                  "-DCADR_BOARD_CORA", "-DCADR_PS7_NO_HP3",
                  "-CFLAGS", "-DCADR_BOARD_CORA"],
        "golden": None,
        "gprom": True,
    },
    "board_reset_de25": {
        "sources": ["rtl/plumbing/cadr_ddr_map.sv", "boards/de25-nano/cadr_de25.sv",
                    "rtl/plumbing/cadr_gp0_split.sv", "rtl/plumbing/cadr_gp1_split.sv",
                    "rtl/plumbing/cadr_gp0_default.sv", "rtl/plumbing/cadr_disk_pack.sv",
                    "rtl/plumbing/cadr_chaos_cable.sv", "rtl/plumbing/cadr_serial_line.sv",
                    "rtl/plumbing/cadr_input_cables.sv", "rtl/plumbing/cadr_console.sv",
                    "rtl/plumbing/cadr_debug_window.sv",
                    "rtl/plumbing/cadr_f2sdram_gate.sv", "rtl/plumbing/cadr_f2sdram_share.sv",
                    "rtl/plumbing/cadr_f2sdram_port.sv", "rtl/plumbing/cadr_display_out.sv"],
        "extra": ["tb/cadr_sim_axi.sv", "tb/cadr_de25_hps_sim.sv", "tb/cadr_de25_stubs.sv",
                  "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
                  "rtl/machine/cadr_xbus_decode.sv",
                  "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
                  "rtl/machine/cadr_spy_registers.sv", "rtl/machine/cadr_disk_controller.sv",
                  "rtl/machine/cadr_tv.sv", "rtl/machine/cadr_io_board.sv",
                  "rtl/machine/cadr_busint_regs.sv", "rtl/machine/cadr_console_bus.sv",
                  "rtl/machine/cadr_console_state.sv", "rtl/machine/cadr_dbgin.sv",
                  "rtl/plumbing/cadr_bus_audit.sv", "rtl/machine/cadr_memory_path.sv",
                  "rtl/machine/cadr_machine.sv",
                  "rtl/plumbing/cadr_dbg_tx.sv", "rtl/plumbing/cadr_dbg_rx.sv",
                  "rtl/plumbing/cadr_dbg_join.sv", "rtl/plumbing/cadr_dbg_cable.sv",
                  "rtl/plumbing/cadr_lamp_errhalt.sv", "rtl/plumbing/cadr_lamp_clock.sv",
                  "rtl/plumbing/cadr_lamp_microcycle.sv",
                  "rtl/plumbing/cadr_axi_master.sv", "rtl/plumbing/cadr_axi_widen.sv",
                  "rtl/plumbing/cadr_mem_count.sv", "rtl/plumbing/cadr_gp_regs.sv",
                  "rtl/plumbing/cadr_adv7513.sv",
                  "tb/cadr_board_reset_harness.sv"],
        "top": "cadr_board_reset_harness",
        "tb": "tb/cadr_board_reset_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Wno-PINCONNECTEMPTY",
                  "-Irtl/machine", "-Irtl/plumbing", "-DCADR_DDR_MAP_DE25_NANO",
                  "-DCADR_BOARD_DE25", "-DCADR_DE25_DDR", "-DCADR_DE25_HDMI",
                  "-DCADR_DE25_HPS_SIM", "-CFLAGS", "-DCADR_BOARD_DE25"],
        "golden": None,
        "gprom": True,
    },
    # THE FAULT BITSTREAM, on each board's own fault top level:
    # `build/fault.pass`, three builds, one a board.  What each holds is in
    # `tb/cadr_fault_tb.cpp`: every lamp in phase, red alone on a color lamp,
    # at the polarity and the rate; every window of both ports answered with
    # "FALT"; the tally "FALT"; no memory master; and on the DE25-Nano the
    # warm-reset handshake.  The default slave has its own check,
    # `gp0_default`, and is carried here.
    "fault_arty": {
        "sources": ["boards/arty-z7-20/cadr_arty_fault.sv",
                    "rtl/plumbing/cadr_fault_lamp.sv"],
        "extra": ["tb/cadr_sim_axi.sv", "tb/cadr_arty_stubs.sv", "tb/cadr_ps7_sim.sv",
                  "rtl/plumbing/cadr_gp0_default.sv", "tb/cadr_fault_harness.sv"],
        "top": "cadr_fault_harness",
        "tb": "tb/cadr_fault_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Wno-PINCONNECTEMPTY", "-Irtl/plumbing",
                  "-DCADR_BOARD_ARTY", "-CFLAGS", "-DCADR_BOARD_ARTY"],
        "golden": None,
    },
    "fault_cora": {
        "sources": ["boards/cora-z7-07s/cadr_cora_fault.sv",
                    "rtl/plumbing/cadr_fault_lamp.sv"],
        "extra": ["tb/cadr_sim_axi.sv", "tb/cadr_arty_stubs.sv", "tb/cadr_ps7_sim.sv",
                  "rtl/plumbing/cadr_gp0_default.sv", "tb/cadr_fault_harness.sv"],
        "top": "cadr_fault_harness",
        "tb": "tb/cadr_fault_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Wno-PINCONNECTEMPTY", "-Irtl/plumbing",
                  "-DCADR_BOARD_CORA", "-DCADR_PS7_NO_HP3", "-CFLAGS", "-DCADR_BOARD_CORA"],
        "golden": None,
    },
    "fault_de25": {
        "sources": ["boards/de25-nano/cadr_de25_fault.sv",
                    "rtl/plumbing/cadr_fault_lamp.sv",
                    "rtl/plumbing/cadr_f2sdram_gate.sv"],
        "extra": ["tb/cadr_sim_axi.sv", "tb/cadr_de25_stubs.sv", "tb/cadr_de25_hps_sim.sv",
                  "rtl/plumbing/cadr_gp0_default.sv", "tb/cadr_fault_harness.sv"],
        "top": "cadr_fault_harness",
        "tb": "tb/cadr_fault_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Wno-PINCONNECTEMPTY", "-Irtl/plumbing",
                  "-DCADR_BOARD_DE25", "-DCADR_DE25_HPS_SIM", "-CFLAGS", "-DCADR_BOARD_DE25"],
        "golden": None,
    },
    "arty": {
        "kind": "lint",
        "sources": ["boards/arty-z7-20/cadr_arty.sv"],
        "extra": ["rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
                  "rtl/plumbing/cadr_ddr_map.sv", "rtl/machine/cadr_xbus_decode.sv",
                  "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
                  "rtl/machine/cadr_spy_registers.sv", "rtl/machine/cadr_disk_controller.sv",
                  "rtl/machine/cadr_tv.sv", "rtl/machine/cadr_console_bus.sv",
                  "rtl/machine/cadr_console_state.sv", "rtl/machine/cadr_memory_path.sv",
                  "rtl/machine/cadr_machine.sv"],
        "top": "cadr_arty",
        "tb": None,
        "flags": [],
        "golden": None,
    },
    # The DE25-Nano's top level, the first board built by Quartus.  Its PLL is
    # generated at build time and its reset release is a primitive Quartus
    # supplies, so it cannot be run as it is built.  What lint holds is the
    # port list and the fold, as for `arty`, in FOUR BOARD CONFIGURATIONS,
    # each a generate arm or a define the others never elaborate, with its
    # own stubs, which `de25_check` puts first.  AND THEN THE TOP LEVEL
    # SIMULATED around shells of those pieces, which is what holds which wire
    # goes where: measured, lint passed eleven crossed or inverted wires of this
    # board, and the simulation fails every one.
    "de25": {
        "kind": "lint",
        "sources": ["boards/de25-nano/cadr_de25.sv"],
        "stubs": ["tb/cadr_de25_stubs.sv"],
        "extra": ["rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
                  "rtl/plumbing/cadr_ddr_map.sv", "rtl/machine/cadr_xbus_decode.sv",
                  "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
                  "rtl/machine/cadr_spy_registers.sv", "rtl/machine/cadr_disk_controller.sv",
                  "rtl/machine/cadr_tv.sv", "rtl/machine/cadr_io_board.sv",
                  "rtl/machine/cadr_busint_regs.sv", "rtl/machine/cadr_console_bus.sv",
                  "rtl/machine/cadr_console_state.sv", "rtl/machine/cadr_dbgin.sv",
                  "rtl/plumbing/cadr_bus_audit.sv", "rtl/machine/cadr_memory_path.sv",
                  "rtl/machine/cadr_machine.sv",
                  "rtl/plumbing/cadr_lamp_clock.sv", "rtl/plumbing/cadr_lamp_microcycle.sv",
                  "rtl/plumbing/cadr_lamp_errhalt.sv"],
        # The probe's board adds these, in `de25_check`'s second pass.
        "probe": ["rtl/plumbing/cadr_probe.sv",
                  "rtl/plumbing/agilex5/cadr_probe_vjtag.sv"],
        # And the memory board's, in its third: the machine's port on the
        # processor's FPGA-to-SDRAM bridge and the default slave both
        # processor-to-fabric bridges are tied to.  Each has records of its
        # own, at `f2sdram` and `gp0_default`.
        "ddr": ["rtl/plumbing/cadr_axi_master.sv", "rtl/plumbing/cadr_axi_widen.sv",
                "rtl/plumbing/cadr_mem_count.sv", "rtl/plumbing/cadr_f2sdram_gate.sv",
                "rtl/plumbing/cadr_f2sdram_share.sv", "rtl/plumbing/cadr_f2sdram_port.sv",
                "rtl/plumbing/cadr_gp0_default.sv",
                "rtl/plumbing/cadr_gp0_split.sv", "rtl/plumbing/cadr_gp_regs.sv",
                "rtl/plumbing/cadr_chaos_cable.sv", "rtl/plumbing/cadr_serial_line.sv",
                "rtl/plumbing/cadr_input_cables.sv", "rtl/plumbing/cadr_disk_pack.sv",
                "rtl/plumbing/cadr_gp1_split.sv", "rtl/plumbing/cadr_console.sv",
                "rtl/plumbing/cadr_debug_window.sv"],
        # And the display output's, in its fourth: the raster every board
        # shares and the HDMI transmitter's own configuration, which is this
        # board's alone.  Each has records of its own, at `display_out` and
        # `adv7513`.  The encoder and the serializers have no counterpart
        # here: the ADV7513 does both.
        "hdmi": ["rtl/plumbing/cadr_display_out.sv", "rtl/plumbing/cadr_adv7513.sv"],
        # **AND THE TOP LEVEL SIMULATED**, as `build/de25.pass` runs it after
        # the four lints: the whole board around the shells in the first two
        # files, with `tb/cadr_de25_top_tb.cpp` as the processor, its memory
        # and the transmitter's bus.  Lint cannot tell a crossed pair of wires
        # from a straight one; this can.  The debug cable's four modules are
        # named here and not left to the include path, because this is a
        # build and not a lint.
        "sim": ["tb/cadr_de25_top.vlt", "tb/cadr_de25_sim_stubs.sv",
                "rtl/plumbing/cadr_ddr_map.sv", "boards/de25-nano/cadr_de25.sv",
                "rtl/plumbing/cadr_lamp_clock.sv", "rtl/plumbing/cadr_lamp_microcycle.sv",
                "rtl/plumbing/cadr_lamp_errhalt.sv",
                "rtl/plumbing/cadr_dbg_tx.sv", "rtl/plumbing/cadr_dbg_rx.sv",
                "rtl/plumbing/cadr_dbg_join.sv", "rtl/plumbing/cadr_dbg_cable.sv"],
        "sim_tb": "tb/cadr_de25_top_tb.cpp",
        "top": "cadr_de25",
        "tb": None,
        "flags": [],
        "golden": None,
    },
    # WHERE THE DE25-NANO'S FACES SIT, which lint cannot see at all: a face is
    # placed by a parameter on its instance, and a number is not something
    # lint has an opinion about.  What makes it checkable is that the address
    # is written twice --- as an OFFSET into the bridge's window on the
    # instance, and as the PROCESSOR's address in `cadr_board.h`, which is
    # where every program takes it from --- so the two can be required to
    # agree.  `tools/de25_faces_check.py` is the whole of it and its header is
    # the argument.  Refusing is being caught.
    "de25_faces": {
        "kind": "script",
        "sources": ["boards/de25-nano/cadr_de25.sv"],
        "cmd": ["tools/de25_faces_check.py", "."],
        "top": None,
        "tb": None,
        "flags": [],
        "golden": None,
    },
    # THE TIMING CONSTRAINTS' COUNTS, held to MIT's grid.  `tools/grid_check.py`
    # requires every multicycle count under `rtl/` and `boards/` to be the
    # count of the instant its `# grid:` tag names, so a clause widened past
    # the time the machine gives its paths --- a tick past the split paths'
    # bounds, which is what a wrong multicycle IS --- is refused.  No
    # simulation can see a constraint, and this is the one check that reads
    # them.  It reads `golden/src/`'s grid constants as well, so the copy
    # carries `golden/` (`golden_tree`).  Refusing is being caught.
    "grid": {
        "kind": "script",
        "golden_tree": True,
        "sources": ["rtl/plumbing/xilinx7/cadr_machine.xdc",
                    "boards/de25-nano/quartus/cadr_de25.sdc",
                    "rtl/plumbing/xilinx7/quux_machine.xdc",
                    "boards/de25-nano/quartus/quux_de25.sdc",
                    "boards/arty-z7-20/cadr_arty.sv"],
        "cmd": ["tools/grid_check.py", "."],
        "top": None,
        "tb": None,
        "flags": [],
        "golden": None,
    },
    # WHICH MACHINE A BOARD IS BUILT AS, "cadr" or "quux": the machine's QUUX
    # checks build `cadr_machine` with the value directly, so a top level that
    # dropped the parameter would build the CADR under the other name with
    # every other check green.
    # `tools/machine_param_check.py` reads the value back at `u_machine` out
    # of Verilator's elaborated tree for each board and each value, requires
    # the refusals of a name that is not a machine and of QUUX on the Cora,
    # and runs the flows' own refusals.  Its header is the argument.
    # Refusing is being caught.
    "machine_param": {
        "kind": "script",
        "sources": ["boards/arty-z7-20/cadr_arty.sv",
                    "boards/de25-nano/cadr_de25.sv",
                    "boards/cora-z7-07s/cadr_cora.sv",
                    "rtl/machine/cadr_machine.sv",
                    "boards/arty-z7-20/vivado/bitstream.tcl",
                    "boards/cora-z7-07s/vivado/bitstream.tcl",
                    "boards/de25-nano/quartus/build.sh",
                    "boards/de25-nano/quartus/program.sh"],
        "cmd": ["tools/machine_param_check.py", "."],
        "top": None,
        "tb": None,
        "flags": [],
        "golden": None,
    },
    # WHERE EACH BOARD'S MEMORY IS, written in several files no one build
    # reads together: the fabric's package, the DE25-Nano's restatement of it,
    # the programs' header, each board's reserved-memory node, the card
    # script, U-Boot's GPO register and the Zynq boards' JTAG memory proofs.
    # `tools/mem_map_check.py` requires them to agree.  Refusing is being
    # caught.
    "mem_map": {
        "kind": "script",
        "sources": ["rtl/plumbing/cadr_ddr_map.sv",
                    "boards/de25-nano/cadr_de25.sv",
                    "boards/arty-z7-20/linux/buildroot/package/cadr-common/src/cadr/cadr_board.h",
                    "boards/arty-z7-20/linux/cadr-reserved.dtsi",
                    "boards/de25-nano/linux/cadr-reserved.dtsi",
                    "boards/arty-z7-20/linux/mksd-buildroot.sh",
                    "boards/de25-nano/linux/buildroot/board/de25-nano/uboot/cadr_de25.env",
                    "boards/arty-z7-20/vivado/ddr_check.tcl",
                    "boards/arty-z7-20/vivado/ddr_run.tcl"],
        "cmd": ["tools/mem_map_check.py", "."],
        "top": None,
        "tb": None,
        "flags": [],
        "golden": None,
    },
    # The DE25-Nano's boot environment, as the `boot` step of
    # `build/de25_linux.pass` reads it: the fabric's image fetched only on the
    # branch that loads it, and only `cadr_fabric_loaded=1` taking the branch
    # that does not.  The rest of that check compiles C, which is the
    # packages' own mutation lists' to hold; this entry is the step that reads
    # U-Boot's environment.  Refusing is being caught.
    "de25_boot": {
        "kind": "script",
        "sources": ["boards/de25-nano/linux/buildroot/board/de25-nano/uboot/cadr_de25.env"],
        "cmd": ["boards/de25-nano/linux/buildroot_check.py", "boot",
                "boards/de25-nano/linux/buildroot"],
        "top": None,
        "tb": None,
        "flags": [],
        "golden": None,
    },
    # The disk controller's drive and register face, against the program
    # `golden/src/disk.rs` writes.  This is the check that can tell this
    # module from a wire: the boot PROM reads one constant out of it 11,301
    # times and writes zero to the disk address register 5,650, so `machine`
    # can see the status word's bits and their DIRECTION and nothing else.
    # Records aimed at the drive, the spindle, the seek, the hang timer and
    # the two resets belong HERE and the ones aimed at `0x2321` belong there;
    # both files are the same module and the two checks see different halves
    # of it.
    #
    # WITH THE PACK SIDE UNDERNEATH.  `tb/cadr_disk_harness.sv` wires
    # `rtl/plumbing/cadr_disk_pack.sv` under the controller as the board does, and the
    # block store is filled only through it --- so a mutation of the pack
    # side can be aimed here too, where the whole trace sees it, as well as at
    # `disk_pack` below, where it is cheap.  The harness is wiring, in
    # `extra`.
    #
    # **IT IS THE SLOWEST CHECK IN THE LIST AND THAT IS A CONSTANT AND NOT A
    # WASTE**: the trace holds one hang run out to 2.56 s, which is
    # 512,000,000 ticks, and the fabric counts every one.  Two minutes a
    # mutation.
    "disk": {
        "sources": ["rtl/machine/cadr_disk_controller.sv", "rtl/plumbing/cadr_disk_pack.sv"],
        "extra": ["tb/cadr_disk_harness.sv"],
        "top": "cadr_disk_harness",
        "tb": "tb/cadr_disk_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": "disk.golden",
    },
    # THE CHANNEL OVER A REAL PACK, and the hole the two above left between
    # them.  `disk` walks lists of three CCWs but every block is in the store
    # before the START that needs it, and `disk_pack` fills the store on
    # demand but every list in it is one CCW long bar a single chained pair
    # whose first block is resident.  So neither could see a channel that
    # honors the first CCW of a list and not the rest --- which is what the
    # board did on 2026-09-10, halting the cold boot at microcode PC `0o5163`.
    # This runs the cold boot's own first two command lists, three CCWs and
    # nine, taken from muir's `rtl` engine on MIT's boot PROM, and compares
    # every word of every page against `Controller::transfer` over the real
    # System 100 pack.
    #
    # IT NEEDS `vendor/`, and says "skipped" and passes without it, as
    # `microcycle_sys` does.  A record aimed here on a machine with no
    # release would be reported caught by a check that never ran, so
    # anything aimed here needs a second record aimed at `disk` or
    # `disk_pack` if it is to mean anything in CI --- which is why the two
    # CCW-walk records below carry `@check disk_boot` and the notes say what
    # else sees them.
    "disk_boot": {
        "sources": ["rtl/machine/cadr_disk_controller.sv", "rtl/plumbing/cadr_disk_pack.sv"],
        "extra": ["tb/cadr_disk_harness.sv"],
        "top": "cadr_disk_harness",
        "tb": "tb/cadr_disk_boot_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": "disk_boot.golden",
    },
    # The pack side held to the property: a record fetched over `S_AXI_HP2`
    # is what the CADR's own transfer then moves into main memory, a block the
    # CADR wrote is the record written back, exactly one handshake per
    # channel per burst, a refusal moves nothing, a slot mid-fill is missed.
    # `tb/cadr_axi_master_tb.cpp`'s situation: no muir reference, the
    # testbench is the stimulus and a counting AXI3 slave the observer.  Same
    # harness as `disk`; the controller is in `sources` because the one
    # controller-side change the pack side needed --- the tag write that takes
    # a block away --- is held here and nowhere else.
    "disk_pack": {
        "sources": ["rtl/plumbing/cadr_disk_pack.sv", "rtl/machine/cadr_disk_controller.sv"],
        "extra": ["tb/cadr_disk_harness.sv"],
        "top": "cadr_disk_harness",
        "tb": "tb/cadr_disk_pack_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": None,
    },
    # The default slave on `M_AXI_GP0`, held to the one property it has: every
    # transaction on the port completes.  A read nothing answers hangs both
    # Arm cores --- measured on the board --- so the board that brings GP0 out
    # without the pack side answers with this; `arty` holds that it is wired,
    # and this holds that it answers.
    "display_out": {
        "sources": ["rtl/plumbing/cadr_display_out.sv"],
        "top": "cadr_display_out",
        "tb": "tb/cadr_display_out_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": None,
    },
    # QUUX's picture, MONO TV at 1280 by 1024, as the Makefile builds it.
    "display_out_quux": {
        "sources": ["rtl/plumbing/cadr_display_out.sv"],
        "top": "cadr_display_out",
        "tb": "tb/cadr_display_out_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2 -DCADR_DISPLAY_QUUX",
                  "-GPIC_W=1280", "-GPIC_H=1024", "-GWORDS_PER_LINE=40",
                  "-GCOLOR_BASE=470024192"],
        "golden": None,
        "machine": "quux",
    },
    # The display output's sleep timer and mute, on the small raster and the
    # short second the Makefile's `DISPLAY_SLEEP_G` builds it with.  The same
    # figures, because a record here must be run against the build the check
    # was written for; `check_makefile` does not compare flags, so the two are
    # kept together by this comment and by the check failing on the frame's
    # own length if they part.
    "display_sleep": {
        "sources": ["rtl/plumbing/cadr_display_out.sv"],
        "top": "cadr_display_out",
        "tb": "tb/cadr_display_sleep_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2",
                  "-GH_ACTIVE=80", "-GH_FRONT=4", "-GH_SYNC=6", "-GH_BACK=10",
                  "-GV_ACTIVE=70", "-GV_FRONT=2", "-GV_SYNC=3", "-GV_BACK=5",
                  "-GPIC_W=64", "-GPIC_H=6", "-GWORDS_PER_LINE=2",
                  "-GCPIC_W=16", "-GCPIC_H=4", "-GCWORDS_PER_LINE=2",
                  "-GMONO_ENTRIES=16", "-GCOLOR_ENTRIES=16", "-GSECOND_T=2000"],
        "golden": None,
    },
    # The display output behind the DE25-Nano's share of one port, against a
    # pipelined memory: the same testbench as `display_out`, built with
    # `CADR_DISPLAY_SHARE` around `tb/cadr_display_share_harness.sv`, which is
    # wiring and in `extra`.  Records aimed at the share's reads in flight
    # belong here: a share that lets the display have one read at a time
    # draws the rotated pictures black.
    "display_share": {
        "sources": ["rtl/plumbing/cadr_f2sdram_share.sv",
                    "rtl/plumbing/cadr_display_out.sv"],
        "extra": ["tb/cadr_display_share_harness.sv"],
        "top": "cadr_display_share_harness",
        "tb": "tb/cadr_display_out_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-CFLAGS", "-DCADR_DISPLAY_SHARE"],
        "golden": None,
    },
    "hdmi_tx": {
        "sources": ["rtl/plumbing/cadr_hdmi_tx.sv", "rtl/plumbing/cadr_tmds_encode.sv"],
        "top": "cadr_hdmi_tx",
        "tb": "tb/cadr_hdmi_tx_tb.cpp",
        "flags": [],
        "golden": None,
    },
    # The HDMI transmitter's own configuration on the DE25-Nano, read off the
    # two wires by a decoder that knows nothing inside the module.
    "adv7513": {
        "sources": ["rtl/plumbing/cadr_adv7513.sv"],
        "top": "cadr_adv7513",
        "tb": "tb/cadr_adv7513_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": None,
    },
    "gp0_default": {
        "sources": ["rtl/plumbing/cadr_gp0_default.sv"],
        "top": "cadr_gp0_default",
        "tb": "tb/cadr_gp0_default_tb.cpp",
        "flags": [],
        "golden": None,
    },
    # `M_AXI_GP0` with four slaves on it: the decode, the AXI3 register face
    # the two new ones share, and the far ends of the I/O board's two cables.
    # The property is that EVERY address on the port is answered in both
    # directions --- a read nothing answers there hangs both Arm cores at one
    # PC each, measured on the board --- and it is demonstrated rather than
    # asserted: each of the four answers with something only it can answer, so
    # the sweep reads the routing off the reply.
    #
    # The harness, the default slave and the pack side are `extra` rather than
    # `sources`: the last two have a check of their own and records aimed at
    # them there, and the harness is wiring.  What is aimed here is the four
    # files nothing else builds --- and the card, for the one reason below.
    "gp0_split": {
        # `cadr_io_board.sv` MOVED FROM `extra` INTO `sources`, which is the
        # rule `bus_audit`'s entry states: a record aimed at a file has to
        # name a check that BUILDS it in `sources`.  The card is otherwise
        # `iob`'s to hold against muir, and two records about `TxEMT` across a
        # driver's turn-off are aimed here instead.  One of them is invisible
        # to `iob` by construction: muir's `Pci::transmit` raises the flag on
        # a drain whatever the transmitter is doing, so a trace generated from
        # muir cannot object to a card that does the same, and `iob` is green
        # over all 82,509,813 ticks with that term deleted.  The other, the
        # clear at the disable, `iob` does catch --- both are measured in the
        # records' own notes.  What sees the pair is this check, where MIT's
        # channel walk runs against the card and the line together.
        "sources": [
            "rtl/plumbing/cadr_gp0_split.sv", "rtl/plumbing/cadr_gp_regs.sv",
            "rtl/plumbing/cadr_chaos_cable.sv", "rtl/plumbing/cadr_serial_line.sv",
            "rtl/plumbing/cadr_input_cables.sv", "rtl/machine/cadr_io_board.sv",
        ],
        "extra": ["tb/cadr_gp0_split_harness.sv",
                  "rtl/plumbing/cadr_gp0_default.sv",
                  "rtl/plumbing/cadr_disk_pack.sv"],
        "top": "cadr_gp0_split_harness",
        "tb": "tb/cadr_gp0_split_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing",
                  "-Irtl/plumbing/xilinx7"],
        "golden": None,
    },
    # AND THE SAME FIVE AT THE DE25-NANO'S SHAPE AND MAP: the HPS-to-FPGA
    # bridge is AXI4, with four bits of ID and EIGHT of burst length, and the
    # faces sit at offsets into its window rather than at the processor's
    # `0x4000_0000`.  The same harness and the same testbench, built as
    # `build/gp0_split.pass` builds them a second time.  A record aimed at
    # what only a burst longer than sixteen beats can reach belongs here;
    # everything else belongs at `gp0_split` above, where it is the same
    # stimulus and says the same thing.  `sources` is the two files that
    # count a read's beats for themselves on this port.
    "gp0_split_axi4": {
        "sources": ["rtl/plumbing/cadr_gp_regs.sv",
                    "rtl/plumbing/cadr_disk_pack.sv"],
        "extra": ["tb/cadr_gp0_split_harness.sv",
                  "rtl/plumbing/cadr_gp0_split.sv",
                  "rtl/plumbing/cadr_chaos_cable.sv",
                  "rtl/plumbing/cadr_serial_line.sv",
                  "rtl/plumbing/cadr_input_cables.sv",
                  "rtl/machine/cadr_io_board.sv",
                  "rtl/plumbing/cadr_gp0_default.sv"],
        "top": "cadr_gp0_split_harness",
        "tb": "tb/cadr_gp0_split_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing",
                  "-Irtl/plumbing/xilinx7",
                  "-GID_W=4", "-GLEN_W=8",
                  "-GPACK_BASE=32'h0000_0000", "-GCHAOS_BASE=32'h0000_1000",
                  "-GSER_BASE=32'h0000_2000", "-GINPUT_BASE=32'h0000_3000",
                  "-CFLAGS", "-DGP_ID_W=4", "-CFLAGS", "-DGP_LEN_W=8",
                  "-CFLAGS", "-DGP_PORT_BASE=0x00000000u"],
        "golden": None,
    },
    # `M_AXI_GP1` split three ways: the decode that lets the console and the
    # debug cable's carrier share the port, with the property `gp0_split`
    # holds on the other one --- every address answered, in both directions,
    # by the slave the map names.  The harness is the attachment and carries
    # MIT's own cable between the window and `cadr_dbgin.sv`, so a record can
    # be aimed at the decode AND at the two roads the port now has onto one
    # register block.
    "gp1_split": {
        "sources": ["rtl/plumbing/cadr_gp1_split.sv"],
        "extra": ["tb/cadr_gp1_split_harness.sv",
                  "rtl/plumbing/cadr_console.sv",
                  "rtl/plumbing/cadr_debug_window.sv",
                  "rtl/plumbing/cadr_gp0_default.sv",
                  "rtl/machine/cadr_dbgin.sv",
                  "rtl/machine/cadr_console_bus.sv",
                  "rtl/machine/cadr_spy_registers.sv"],
        "top": "cadr_gp1_split_harness",
        "tb": "tb/cadr_gp1_split_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing",
                  "-Irtl/plumbing/xilinx7"],
        "golden": None,
    },
    # AND THE SAME THREE ON THE DE25-NANO'S LIGHTWEIGHT BRIDGE, which is AXI4
    # with four bits of ID and eight of burst length, a window of 512 MB, and
    # the console at offset 0 with the cable's page above it.  `sources` is
    # the two faces that count a read's beats for themselves; a record aimed
    # at what only a burst longer than sixteen beats can reach belongs here.
    "gp1_split_axi4": {
        "sources": ["rtl/plumbing/cadr_console.sv",
                    "rtl/plumbing/cadr_debug_window.sv"],
        "extra": ["tb/cadr_gp1_split_harness.sv",
                  "rtl/plumbing/cadr_gp1_split.sv",
                  "rtl/plumbing/cadr_gp0_default.sv",
                  "rtl/machine/cadr_dbgin.sv",
                  "rtl/machine/cadr_console_bus.sv",
                  "rtl/machine/cadr_spy_registers.sv"],
        "top": "cadr_gp1_split_harness",
        "tb": "tb/cadr_gp1_split_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing",
                  "-Irtl/plumbing/xilinx7",
                  "-GID_W=4", "-GLEN_W=8",
                  "-GCON_BASE=32'h0000_0000", "-GDBG_BASE=32'h0000_1000",
                  "-CFLAGS", "-DGP_ID_W=4", "-CFLAGS", "-DGP_LEN_W=8",
                  "-CFLAGS", "-DGP_PORT_BASE=0x00000000u",
                  "-CFLAGS", "-DGP_PORT_PAGES=131072u"],
        "golden": None,
    },
    # The console: the sixteen diagnostic registers on `M_AXI_GP1`, held to
    # `Engine::spy_read` over MIT's boot PROM.  The harness is the console,
    # `cadr_spy_registers.sv` and the REAL processor, with the arbiter that
    # `rtl/machine/cadr_memory_path.sv` instantiates --- the same module, not a copy
    # of it --- so a mutation of either is caught by what the console reads
    # back at a microcycle the reference names, by the AXI3 protocol on the
    # face, or by the sweep that measures the read-back's lag with the machine
    # running.
    "console": {
        # `cadr_spy_registers.sv` moved out of `extra` and into `sources`
        # when this check stopped MEASURING the single step and started
        # ASSERTING it.  A record aimed at the clock control register's own
        # write belongs where the whole road is exercised --- an AXI write, a
        # Unibus cycle, the landing rule and MACHRUN's first term --- and that
        # is here.  `unibus` also has the file in `sources`, for the address
        # match; the two see different halves of one module.
        "sources": ["rtl/plumbing/cadr_console.sv", "rtl/machine/cadr_console_bus.sv",
                    "rtl/machine/cadr_console_state.sv",
                    "rtl/machine/cadr_spy_registers.sv"],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "tb/cadr_console_harness.sv",
        ],
        "top": "cadr_console_harness",
        "tb": "tb/cadr_console_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": "rtl.golden",
        "gprom": True,
    },
    # The debug cable's debuggee end: `rtl/machine/cadr_dbgin.sv` is MIT's own
    # DBGIN page and `rtl/plumbing/cadr_debug_window.sv` is the carrier muir
    # reaches with loads and stores.
    #
    # **`cadr_console_bus.sv` IS IN `sources` HERE AND IN `console`'s, AND
    # THAT IS THE SPLIT ON PURPOSE.**  It is one arbiter with three masters,
    # and each check can only see its own: `console` reaches the console's arm
    # and the processor's, and nothing there raises `dbg_req` at all, so the
    # arm this slice added is aimed at from here.  A record aimed at either
    # file is re-run against the other check that builds it, which is what
    # `--since` and the cross-check are for.
    #
    # The processor and the register block are in `extra` for the reason
    # `console` has them there: they are what the cable reaches, they are held
    # to muir by their own checks, and a mutation of either belongs where a
    # reference trace can see it.
    "dbgin": {
        "sources": ["rtl/machine/cadr_dbgin.sv",
                    "rtl/plumbing/cadr_debug_window.sv",
                    "rtl/machine/cadr_console_bus.sv"],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/machine/cadr_spy_registers.sv",
            "tb/cadr_dbgin_harness.sv",
        ],
        "top": "cadr_dbgin_harness",
        "tb": "tb/cadr_dbgin_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": "rtl.golden",
        "gprom": True,
    },
    # The debug cable's carrier, the module that puts one direction of MIT's
    # twenty-one wires on eight pins, and the join that lets the connector and
    # the window share one DBGIN page.  Neither has a muir reference --- muir
    # has the cable and no wires --- so what holds them is a property, which
    # is the footing `axi_master` is on.
    #
    # THE TESTBENCH IS THE CABLE: the harness brings the eight wires of each
    # connector out as ports, so a record that drops a line or crosses two has
    # something watching that is not the DUT's own arithmetic.  The composed
    # half of it runs a real debug cycle through the carrier into
    # `cadr_dbgin.sv` and the real register block, so a carrier fault shows as
    # a debugger that cannot read a register rather than as a bit.
    # AND THE CONNECTOR ABOVE IT, which is where the ROLE is: one Pmod header
    # carrying both directions, four pins each, and which four of them this
    # board drives.  The DUT is two boards --- one running the DBGOUT page
    # `rtl/machine/cadr_busint_regs.sv` and one answering through
    # `rtl/machine/cadr_dbgin.sv` --- so a fault here shows as a debugger that
    # cannot read the other machine's register, or as a pad driven from both
    # ends, which the testbench counts on every tick.
    "dbg_cable": {
        # **THE JOIN IS MUTABLE HERE AS WELL AS UNDER `dbg_pmod`**, and that
        # is deliberate.  This check is the only one with two whole boards on
        # one cable, so it is the only one that can ask what the join does on
        # a board that holds the cable's other role --- which is the case
        # `docs/debug-cable.md` calls "only the connector changes hands".
        # **AND THE CARRIER IS MUTABLE HERE AS WELL AS UNDER `dbg_pmod`**, for
        # the join's reason one line down: this is the only check with two
        # whole boards on one cable, so it is the only one that can ask what a
        # receiver does about the group its own board is driving --- which is
        # the question the frame counts and the wiring's detection both rest
        # on, and which a carrier alone cannot be asked.
        # **AND THE DEBUGGEE'S END IS MUTABLE HERE, FOR THE ROUND TRIP'S
        # BOUND.**  `dbgin` holds `cadr_dbgin.sv`'s instants to muir; what
        # nothing else holds is how much of the debugger's deadline the far
        # machine's own cycle spends, and a bound's tightness is tested by a
        # mutation just outside it.  The same reason puts it in `dbg_pmod`.
        "sources": ["rtl/plumbing/cadr_dbg_cable.sv",
                    "rtl/plumbing/cadr_dbg_tx.sv",
                    "rtl/plumbing/cadr_dbg_rx.sv",
                    "rtl/plumbing/cadr_dbg_join.sv",
                    "rtl/machine/cadr_dbgin.sv"],
        "extra": ["tb/cadr_dbg_cable_harness.sv",
                  "rtl/machine/cadr_busint_regs.sv",
                  "rtl/machine/cadr_console_bus.sv",
                  "rtl/machine/cadr_spy_registers.sv"],
        "top": "cadr_dbg_cable_harness",
        "tb": "tb/cadr_dbg_cable_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing"],
        "golden": None,
    },
    "dbg_pmod": {
        "sources": ["rtl/plumbing/cadr_dbg_tx.sv",
                    "rtl/plumbing/cadr_dbg_rx.sv",
                    "rtl/plumbing/cadr_dbg_join.sv",
                    "rtl/machine/cadr_dbgin.sv"],
        "extra": ["tb/cadr_dbg_pmod_harness.sv",
                  "rtl/plumbing/cadr_debug_window.sv",
                  "rtl/machine/cadr_console_bus.sv",
                  "rtl/machine/cadr_spy_registers.sv"],
        "top": "cadr_dbg_pmod_harness",
        "tb": "tb/cadr_dbg_pmod_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": None,
    },
    # The readout of the machine's memories, page 0's words 10, 11 and 12 ---
    # the same harness as `console`, with a different testbench.  What is
    # aimed here is the window: the address register in `cadr_console.sv`, the
    # three-tick pipeline at the end of `cadr_microcycle.sv`, the second read
    # port of every memory and the echo.
    #
    # **`sources` names `cadr_microcycle.sv`, WHICH `console` HAS IN `extra`,
    # and that is the split on purpose**: a mutation of the processor's own
    # datapath belongs at `microcycle`, where a reference trace can see it,
    # and a mutation of the readout belongs here, where nothing else looks.
    # A record aimed at the microcycle's datapath and routed to this check
    # would be caught by accident or not at all --- this testbench runs no
    # trace and compares no column of one.
    "readout": {
        "sources": ["rtl/machine/cadr_microcycle.sv", "rtl/plumbing/cadr_console.sv"],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
            "tb/cadr_console_harness.sv",
        ],
        "top": "cadr_console_harness",
        "tb": "tb/cadr_readout_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "--public-flat-rw", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": None,
        "gprom": True,
    },
    # The I/O board --- the keyboard, the mouse, the two clocks and the status
    # register they share, on the Unibus --- against the scripted program
    # `golden/src/iob.rs` writes out of muir's own `ioboard::IoBoard` through
    # `busint::IoBoardTiming`.
    #
    # A SCRIPTED PROGRAM BECAUSE NEITHER REFERENCE PROGRAM ASKS ANYTHING OF THE
    # CARD.  Measured: MIT's boot PROM never addresses it at all in 600,000
    # microcycles, and a System 100 band reaches three of its registers in 271
    # bus cycles of 141,849 --- one read of the status register, 135 reads of
    # each half of the microsecond counter, and one write of the keyboard's
    # interrupt enable.  So this is the only check that can tell this module
    # from a wire, and every record aimed at the card belongs here.
    #
    # The run is about twenty seconds: 81 million ticks of the trace, and then
    # a real bus cycle at every one of the 524,288 addresses and directions an
    # eighteen-bit `ub_addr` can carry.
    "iob": {
        "sources": ["rtl/machine/cadr_io_board.sv"],
        "top": "cadr_io_board",
        "tb": "tb/cadr_io_board_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": "iob.golden",
    },
    # The bus interface's own Unibus registers at their own seam: the
    # interrupt block at `0o766040`-`0o766076` and the Unibus map at
    # `0o766140`-`0o766176`, against muir's `busint::register` and
    # `Machine::interface_read` and `interface_write`.
    #
    # WHAT BELONGS HERE AND NOT IN `unibus`.  This one drives the block alone
    # and is the only thing that can tell the module from a wire: every word
    # a register gives or takes, the two write masks, `-RESET ERR`, the
    # aliasing of the interrupt block's four every eight bytes and of the
    # map's sixteen across their odd addresses, and the decode at all 262,144
    # addresses.  `unibus` drives a cycle of the MACHINE'S and holds the
    # three slaves apart on one bus; records aimed at the join or at the mux
    # belong there.
    #
    # The run is a few seconds: 251 rows with two face reads each, then a
    # real bus cycle at every one of the 524,288 addresses and directions.
    "busint_regs": {
        "sources": ["rtl/machine/cadr_busint_regs.sv"],
        "top": "cadr_busint_regs",
        "tb": "tb/cadr_busint_regs_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": "busint_regs.golden",
    },
    # The I/O board UNDER THE MACHINE: the composition of slice three, which
    # put the card on the Unibus beside the diagnostic register block.  Same
    # module list as `memory_path` with the card added, because the card is
    # instantiated inside `cadr_memory_path` and the DUT is the path rather
    # than a harness of it --- the display's arrangement exactly.
    #
    # WHAT BELONGS HERE AND NOT IN `iob`.  `iob` drives the card alone and is
    # the only thing that can tell that module from a wire; this one drives a
    # cycle of the MACHINE'S and is the only thing that can tell the
    # composition from a wire.  So records aimed at the `-UB SSYN` join, at the
    # mux on the word, at either slave's address match reaching the other's
    # block, and at the bus interface's two Unibus instants belong here.
    #
    # `iob.golden` is its reference, for the decode table it carries:
    # `ioboard::answers` for all 262,144 Unibus addresses in both directions.
    # Everything else the run compares is its own stimulus.
    "unibus": {
        "sources": [
            "rtl/plumbing/cadr_ddr_map.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv",
            "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_console_bus.sv",
            "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_io_board.sv",
            "rtl/machine/cadr_busint_regs.sv",
            "rtl/machine/cadr_memory_path.sv",
        ],
        "top": "cadr_memory_path",
        "tb": "tb/cadr_unibus_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing",
                  "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        # TWO traces, and the second is what made the first honest: the card's
        # decode comes out of `iob.golden` and the bus interface's out of
        # `busint_regs.golden`, so neither block's address set is this
        # testbench's own transcription.
        "golden": ["iob.golden", "busint_regs.golden"],
    },
    # The two generators that check themselves.  Nothing downstream of these
    # can catch a bad one: `cables` is the only authority on the port list,
    # and `busint_xbus` writes the stimulus AND the expected outputs, so a
    # trace agreeing with itself proves nothing.  What stands in for a check
    # is the generator's own assertions, and the question these ask is
    # whether those assertions are live.
    #
    # `kind: generator` means the check is `cargo run`: the generator
    # refusing to write a trace is the mutation being caught.
    "cables_gen": {
        "kind": "generator",
        "bin": "cables",
        "sources": ["golden/src/cables.rs"],
        "golden": None,
    },
    "busint_gen": {
        "kind": "generator",
        "bin": "busint_xbus",
        "sources": ["golden/src/busint_xbus.rs"],
        "golden": None,
    },
}

# The same programs, and muir's own of QUUX, on the machine built as QUUX:
# `golden/src/dispatch_write_order.rs --machine quux`.  QUUX's wait for MD,
# its old word in a RAM's own write cycle and its one rate are held here.
CHECKS["dispatch_write_order_quux"] = dict(CHECKS["dispatch_write_order"], **{
    "sources": CHECKS["dispatch_write_order"]["sources"] + ["rtl/machine/quux_phase_gen.sv"],
    "extra": CHECKS["dispatch_write_order"]["extra"] + [
        f for f in QUUX_SOURCES if f != "rtl/machine/quux_phase_gen.sv"],
    "flags": CHECKS["dispatch_write_order"]["flags"] + ['-GMACHINE="quux"'],
    "golden": "dispatch_write_order.quux.golden",
    "machine": "quux",
})

# **QUUX'S TIMINGS (H1a).**  Every check that holds QUUX to a trace of muir's
# `rtl` holds it at a microcycle of K ticks, and the trace and the build name
# K (`QUUX_TIMED` in the Makefile): `<check>.quux.k4.golden`, built with
# `-GSYNC_K=4`.  The keys above are K = 4, both boards' K and the least QUUX
# takes (`quux_phase_gen.sv` says why).  `quux_divmd_quux_l1` and `quux_divmdsync_quux_l1`
# are the machine checks at an L of one, and `phase_gen_quux` holds the
# generator alone at K and K + 1.  A key missing here selects zero records
# and reports success, which is why the keys are made by rule and not by hand.
def _timed(key, k, l):
    spec = CHECKS[key]
    tag = "k%d" % k + ("l%d" % l if l else "")
    golden = spec["golden"].replace(".quux.golden", ".quux.%s.golden" % tag)
    assert golden != spec["golden"], key
    return dict(spec, **{
        "flags": spec["flags"] + ["-GSYNC_K=%d" % k, "-GSYNC_L=%d" % l],
        "golden": golden,
    })

QUUX_TIMED_KEYS = ["machine_quux", "dispatch_write_order_quux"] + \
    ["quux_%s_quux" % p for p in ("map", "tv", "muldiv", "clocks", "divmd", "tickwin", "pdlsync",
                                  "imemsync", "page", "clockwait")]
CHECKS["quux_divmd_quux_l1"] = _timed("quux_divmd_quux", 4, 1)
CHECKS["quux_tickwin_quux_l1"] = _timed("quux_tickwin_quux", 4, 1)
CHECKS["quux_clockwait_quux_l1"] = _timed("quux_clockwait_quux", 4, 1)
# `divmdsync`, QUUX's alone, at an L of one: its `ILONG` fillers are
# what moves a read's word into the ticks between a `DIV`'s edge and its load.
CHECKS["quux_divmdsync_quux"] = dict(CHECKS["quux_divmd_quux"], **{
    "golden": "quux_divmdsync.quux.golden",
    "prom": "quux_divmdsync_prom.quux.hex",
})
CHECKS["quux_divmdsync_quux_l1"] = _timed("quux_divmdsync_quux", 4, 1)
del CHECKS["quux_divmdsync_quux"]
for _key in QUUX_TIMED_KEYS:
    CHECKS[_key] = _timed(_key, 4, 0)
for _key, (_k, _l) in (("phase_gen_quux", (4, 1)),):
    CHECKS[_key] = {
        "sources": ["rtl/machine/quux_phase_gen.sv"],
        "top": "quux_phase_gen",
        "tb": "tb/quux_phase_gen_tb.cpp",
        "flags": ["-GSYNC_K=%d" % _k, "-GSYNC_L=%d" % _l,
                  "-CFLAGS", "-DSYNC_K_TB=%d -DSYNC_L_TB=%d" % (_k, _l)],
        "golden": "phase_gen.quux.k%dl%d.golden" % (_k, _l),
        "machine": "quux",
    }

# The three files golden/src/cables.rs writes.  `current` regenerates them and
# fails if anything moved; this does the same to a copy.
GENERATED = [
    "rtl/machine/cadr_cables.svh",
    "rtl/machine/cadr_cables.map",
    "rtl/machine/cadr_cables_lint.sv",
]

# What a mutation run comes to.  The first two are what a healthy run is made
# of; the last four each fail it.
CAUGHT = "caught"        # the check failed, as it should have
HOLE = "hole"            # survived, and `@hole` says which issue holds it
SURVIVED = "survived"    # survived with nothing recorded: a new finding
CLOSED = "closed"        # caught, and still carrying an `@hole`
BROKEN = "broken"        # the build failed; not a verdict on the check
UNAPPLIED = "unapplied"  # the @old text was not there exactly once

# The order they are counted and printed in.
VERDICTS = [CAUGHT, HOLE, SURVIVED, CLOSED, BROKEN, UNAPPLIED]


class Mutation(object):
    def __init__(self, name, check, path, notes, old, new, line,
                 hole, hole_line, build_fails=False):
        self.name = name
        self.check = check
        self.path = path
        self.notes = notes
        self.old = old
        self.new = new
        self.line = line          # where it is in list.txt, for error messages
        self.hole = hole          # the issue holding it open, "#3", or None
        self.hole_line = hole_line
        self.build_fails = build_fails   # @build-fails: the refusal is the catch
        self.verdict = None
        self.detail = ""
        self.also = []            # for a survivor: other checks that missed it
        self.was_caught_at = None  # a revision where this used to be caught


def parse(path):
    """Read list.txt.

    Each record names a check, a file, and an exact block of source with what
    to put in its place.  Blocks are literal and whole lines: no line numbers
    and no context, so a record rots only when the lines it actually names
    change, and it reads as prose about the bug rather than as a diff.
    """
    with open(path) as f:
        lines = f.read().split("\n")

    mutations = []
    i = 0
    cur = None
    field = None   # None, "old" or "new" --- which block we are inside
    old, new, notes = [], [], []

    while i < len(lines):
        line = lines[i]
        i += 1
        n = i  # 1-based line number of `line`

        if field in ("old", "new"):
            # Inside a block every line is literal source, so only the three
            # delimiters are read and nothing else is stripped or trimmed.
            if line == "@new":
                if field != "old":
                    die("%s:%d: @new outside @old" % (path, n))
                field = "new"
                continue
            if line == "@end":
                if cur is None:
                    die("%s:%d: @end without @mutation" % (path, n))
                cur["old"] = "".join(s + "\n" for s in old)
                cur["new"] = "".join(s + "\n" for s in new)
                mutations.append(
                    Mutation(cur["name"], cur["check"], cur["file"], notes,
                             cur["old"], cur["new"], cur["line"],
                             cur["hole"], cur["hole_line"],
                             cur["build_fails"]))
                cur, field = None, None
                old, new, notes = [], [], []
                continue
            (old if field == "old" else new).append(line)
            continue

        if not line.strip() or line.startswith("#"):
            continue

        if line.startswith("@mutation "):
            if cur is not None:
                die("%s:%d: @mutation inside a record" % (path, n))
            cur = {"name": line[len("@mutation "):].strip(), "line": n,
                   "check": None, "file": None, "hole": None,
                   "build_fails": False,
                   "hole_line": 0}
            old, new, notes = [], [], []
        elif cur is None:
            die("%s:%d: %s outside a record" % (path, n, line.split()[0]))
        elif line.startswith("@check "):
            cur["check"] = line[len("@check "):].strip()
        elif line.startswith("@file "):
            cur["file"] = line[len("@file "):].strip()
        elif line.startswith("@hole "):
            # An issue number is the whole point: a hole nobody wrote down is
            # not a recorded exception, it is a suppressed finding.
            if cur["hole"]:
                die("%s:%d: `%s` has two @hole lines" % (path, n, cur["name"]))
            hole = line[len("@hole "):].strip()
            if not (hole.startswith("#") and hole[1:].isdigit()):
                die("%s:%d: `%s`: @hole wants an issue, as `@hole #3`, not `%s`"
                    % (path, n, cur["name"], hole))
            cur["hole"], cur["hole_line"] = hole, n
        elif line == "@build-fails":
            # For a check that IS lint, a mutant the build refuses is normally
            # BROKEN and not a verdict.  `cables` is the exception: it mutates
            # a GENERATED header, and the header failing to elaborate is the
            # finding itself.  A record says so here rather than the runner
            # guessing from the check's name.
            cur["build_fails"] = True
        elif line == "@note" or line.startswith("@note "):
            # A bare `@note` is a blank line between paragraphs.
            notes.append(line[len("@note"):].strip())
        elif line == "@old":
            for key in ("check", "file"):
                if not cur[key]:
                    die("%s:%d: `%s` has no @%s" % (path, n, cur["name"], key))
            field = "old"
        else:
            die("%s:%d: cannot read: %s" % (path, n, line))

    if cur is not None or field is not None:
        die("%s: the last record has no @end" % path)
    if not mutations:
        die("%s: no mutations" % path)

    # Names are how a survivor is reported and how a claim about the list is
    # read against it, so two of them may not collide.
    seen = {}
    for m in mutations:
        if m.name in seen:
            die("%s:%d: `%s` is also at line %d"
                % (path, m.line, m.name, seen[m.name]))
        seen[m.name] = m.line
        if m.check not in CHECKS:
            die("%s:%d: `%s` names no check `%s`"
                % (path, m.line, m.name, m.check))
        # A mutation to a file its check does not build would run a clean
        # design and be reported as caught or survived on no evidence.
        if m.path not in CHECKS[m.check]["sources"]:
            die("%s:%d: `%s` mutates %s, which `%s` does not build"
                % (path, m.line, m.name, m.path, m.check))
        if not m.old.strip():
            die("%s:%d: `%s` has an empty @old" % (path, m.line, m.name))
        if m.old == m.new:
            die("%s:%d: `%s` changes nothing" % (path, m.line, m.name))
    return mutations


def die(msg):
    sys.stderr.write("mutations: %s\n" % msg)
    sys.exit(2)


def needs_golden(check):
    """Whether a check's copy must carry `golden/`: a generator's, which is
    built there, and a script that reads it, which says so in `golden_tree`."""
    spec = CHECKS[check]
    return spec.get("kind") == "generator" or bool(spec.get("golden_tree"))


def copy_tree(dest, with_golden=False, rev=None):
    """A private rtl/ and tb/ to mutate.  Never the working tree.

    With `rev`, the copy comes from that commit rather than from the files on
    disk.  That is not a convenience: this repository is worked on by more
    than one session at a time, and a run that reads the working tree reads
    whatever the others have half-written.  It happened --- a baseline that
    passed at one moment failed twenty-four microcycles in at the next,
    because the module under it had been saved twice in between, and the
    results either side of that were of two different designs.  A mutation
    run against a moving tree is not wrong so much as meaningless.
    """
    if os.path.exists(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    # `boards` as well as `rtl` and `tb`:
    # `boards/arty-z7-20/vivado/probe.tcl` is the source the probe_jtag
    # mutations are aimed at, and the working tree is no more mutable for a
    # Tcl script than for a module.
    # Widening this list is a
    # known trap --- `git archive` refuses a pathspec matching nothing, and
    # `--since` names revisions older than the directory --- and the `cat-file
    # -e` filter below is what makes it safe.  And `tools`:
    # `program.tcl` sources `tools/build_stamp.tcl` for the build a bitstream
    # names, so a copy without it is a copy where that script does not run at
    # all --- every record "caught" for the wrong reason and the baseline
    # BROKEN.
    # It is 108 KB and `tools/` arrives at 2e54886, well inside the history
    # `--since` reaches, so the filter earns its keep here rather than being
    # tested by it.
    dirs = ["rtl", "tb", "boards",
            "tools"] + (["golden"] if with_golden else [])
    if rev:
        # A directory that did not exist at `rev` is not an error, and this is
        # not hypothetical: `--since` names EARLIER revisions on purpose, and
        # `vivado/` only arrives at dd6f659 --- 71 commits into a history of
        # 103. `git archive` refuses a pathspec that matches nothing, so
        # passing all three unconditionally would kill every `--since` run
        # against anything older than that, for every record in the list, with
        # a message about a pathspec rather than about the revision.
        present = [d for d in dirs
                   if subprocess.call(
                       ["git", "-C", REPO, "cat-file", "-e", "%s:%s" % (rev, d)],
                       stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL) == 0]
        if not present:
            die("%s: none of %s is there" % (rev, ", ".join(dirs)))
        # `git archive` gives the committed content and nothing else, so an
        # untracked or half-saved file cannot reach the copy.
        tar = subprocess.Popen(["git", "-C", REPO, "archive", rev] + present,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        rc = subprocess.call(["tar", "-x", "-C", dest], stdin=tar.stdout)
        tar.stdout.close()
        err = tar.communicate()[1].decode("utf-8", "replace")
        if tar.returncode != 0 or rc != 0:
            die("git archive %s: %s" % (rev, err.strip() or "failed"))
        if with_golden:
            shutil.rmtree(os.path.join(dest, "golden", "target"), True)
        return
    for d in dirs:
        shutil.copytree(os.path.join(REPO, d), os.path.join(dest, d),
                        ignore=shutil.ignore_patterns("target"))


def muir_beside(work):
    """Put muir where a mutant copy's Cargo.toml will look for it.

    golden/Cargo.toml says `muir = { path = "../../muir" }`, which from
    <work>/<name>/golden resolves to <work>/muir.  So one link at the root of
    the work directory serves every mutation --- and, because it is the same
    resolved path for all of them, muir is built once and cached rather than
    once per mutation.
    """
    manifest = os.path.join(REPO, "golden", "Cargo.toml")
    with open(manifest) as f:
        text = f.read()
    match = re.search(r'muir\s*=\s*\{[^}]*path\s*=\s*"([^"]+)"', text)
    if not match or match.group(1) != "../../muir":
        die("golden/Cargo.toml's muir path is %r, not '../../muir'; the link "
            "the generator mutations rely on no longer resolves"
            % (match.group(1) if match else None))
    real = os.path.abspath(os.path.join(REPO, "golden", "../../muir"))
    if not os.path.isdir(real):
        die("%s: muir is not beside this repository" % real)
    link = os.path.join(work, "muir")
    if not os.path.islink(link):
        os.symlink(real, link)


def apply(work, m, listing):
    """Put the mutation in.  Exactly one occurrence, or it is a failure.

    Nothing about a mutation that did not apply is visible later --- the build
    is clean and the check passes --- so this is the one place it can be
    caught, and it is fatal rather than skipped.
    """
    path = os.path.join(work, m.path)
    # The file may simply not be there --- `--since` runs a record against an
    # earlier revision, and a mutation of a file added after it has nothing to
    # apply to. Reported the same way as an anchor that does not match, which
    # `before()` reads as "not caught there", rather than raised out of a
    # worker thread and taking the run with it.
    if not os.path.exists(path):
        return ("%s:%d: `%s` has no %s to mutate there"
                % (listing, m.line, m.name, m.path))
    with open(path) as f:
        src = f.read()
    n = src.count(m.old)
    if n != 1:
        return ("%s:%d: `%s` matches %s %d times, want exactly once"
                % (listing, m.line, m.name, m.path, n))
    with open(path, "w") as f:
        f.write(src.replace(m.old, m.new))
    return None


def run(cmd, cwd, env=None):
    if env is not None:
        merged = os.environ.copy()
        merged.update(env)
        env = merged
    p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, env=env)
    out = p.communicate()[0].decode("utf-8", "replace")
    return p.returncode, out


def build_env(args):
    """The environment a Verilator build runs in: ccache, when asked for.

    **A CACHED OBJECT IS NOT A STALE BINARY.**  `docs/mutations.md`'s trap is
    a build that did not happen and an old executable that ran.  ccache keys
    each object on the compiler, its flags and the preprocessed text of the
    translation unit, so a mutated unit is a miss and is compiled; what hits
    is text no mutation touched, and above all Verilator's own runtime,
    `verilated.cpp`, which every build here compiled afresh.  The link always
    runs.  `CCACHE_BASEDIR` makes the per-mutant absolute paths relative, so
    one mutant's unchanged units hit for the next.  ccache locks its own
    cache, so the jobs share it safely.  Without `--ccache` the environment
    is left alone and every build compiles everything, as before.
    """
    if not args.ccache:
        return None
    return {"OBJCACHE": "ccache", "CCACHE_DIR": args.ccache,
            "CCACHE_BASEDIR": args.work, "CCACHE_MAXSIZE": args.ccache_size}


def panic_message(out):
    """What a generator said as it refused, not merely that it did.

    A Rust panic is two lines: `thread 'main' panicked at src/cables.rs:189:9:`
    and then the message.  The header alone is the same for every mutation of
    one file, so a report built on it says nothing about which assertion
    fired --- and two mutations tripping two different assertions would read
    identically.
    """
    lines = out.split("\n")
    for i, line in enumerate(lines):
        if "panicked at" in line:
            where = line.split("panicked at", 1)[1].strip().rstrip(":")
            for after in lines[i + 1:]:
                if after.strip():
                    return "%s: %s" % (where, after.strip())
            return where
    return first_problem(out)


def first_problem(out):
    """The one line of a build or check failure worth putting in the table."""
    for line in out.split("\n"):
        s = line.strip()
        if s.startswith("%Error") or s.startswith("%Warning") or \
           s.startswith("FAIL") or s.startswith("tick ") or \
           s.startswith("boards="):
            return s
    for line in out.split("\n"):
        if line.strip():
            return line.strip()
    return "(no output)"


def lint_verdict(out, build_fails=False):
    """A lint that exited non-zero: caught, or a mutant that did not compile?

    For a check that IS lint, the exit status cannot tell the two apart, and
    it did not: `the-request-path-reaches-no-pin` was reported CAUGHT at the
    request path's slice on a `@new` that left a dangling comma --- a syntax
    error, not a lint finding.  A build failure must never read as caught;
    the simulation path has made it BROKEN since the runner was written and
    this path had not.

    The tell is Verilator's own vocabulary, measured on 5.032: a lint
    finding is `%Warning-CODE:` and the run ends `%Error: Exiting due to N
    warning(s)`; a mutant that does not compile prints `%Error:` (a syntax
    error) or `%Error-CODE:` (a pin that does not exist, an unsupported
    construct) and ends `... N error(s)`.  So any `%Error` line that is not
    the summary is the build failing, and the verdict is BROKEN with that
    line; otherwise the warning is the catch.

    UNLESS the record says the build is the catch.  `cables` mutates a
    GENERATED header, `rtl/machine/cadr_cables.svh`, and the thing it is holding is
    that the header is what the generator writes: a renamed port or a lost
    enable makes the port list no longer elaborate, and that refusal IS the
    finding.  Two such records went BROKEN when this classifier landed ---
    `a-signal-is-renamed` and `a-bidirectional-wire-loses-its-enable` --- so a
    record declares which it expects with `@build-fails`, and only then is an
    error the catch.  A record without it keeps the strict reading, which is
    what caught the dangling comma.
    """
    for line in out.split("\n"):
        t = line.strip()
        if t.startswith("%Error") and not t.startswith("%Error: Exiting due to"):
            return (CAUGHT if build_fails else BROKEN), t
    if build_fails:
        return BROKEN, "the build was expected to fail and did not"
    return CAUGHT, first_problem(out)


def build_and_run(args, work, check, build_fails=False):
    """Verilate the check in `work` and run it.  Returns a verdict."""
    spec = CHECKS[check]
    if spec.get("kind") == "generator":
        return generator_check(args, work, spec)
    if spec.get("kind") == "tcl":
        return tcl_check(args, work, spec)
    if spec.get("kind") == "script":
        return script_check(args, work, spec)
    if check == "cables":
        return cables_check(args, work, build_fails)
    if check == "arty":
        return arty_check(args, work, build_fails)
    if check == "de25":
        return de25_check(args, work, build_fails)

    # MIT's TV sync PROM, placed for EVERY check rather than named check by
    # check.  `cadr_tv.sv` reads it at elaboration and its `SYNC_PROM_HEX`
    # defaults to a relative `build/sync_prom.hex`, which the mutant's own
    # working directory is what resolves; the display reaches this runner
    # through six tops and a dozen harnesses, and a list of which ones would
    # have to be kept in step with `rtl/` by hand.  512 bytes a mutant is
    # cheaper than that list being wrong, and a check that does not build the
    # display simply does not read it.  A sync program of zeros is a display
    # that never interrupts, which is why the module makes a missing file
    # loud rather than letting it pass as a check that caught something.
    placed = list(spec.get("files", [])) + [("sync_prom.hex", "build/sync_prom.hex")]
    for src, dest in placed:
        # `exist_ok`, because the two processor checks place the same image
        # and the baseline runs them at once: two threads reaching the same
        # missing directory is a race, and it lost one.
        where = os.path.join(work, dest)
        os.makedirs(os.path.dirname(where), exist_ok=True)
        if not os.path.exists(where):
            shutil.copy(os.path.join(args.goldens, src), where)

    obj = os.path.join(work, "obj_" + check)
    cmd = [args.verilator, "--cc", "--exe", "--build", "-Wall"]
    cmd += spec["flags"]
    if spec.get("gprom_path"):
        # A check that writes its own PROM names it here, and it is placed in
        # the mutant's work directory so two mutants cannot share one file.
        cmd += ["-GPROM_HEX=\"%s\""
                % os.path.join(work, spec["gprom_path"])]
    elif spec.get("prom"):
        # A check built with a PROM image of its own among the goldens:
        # QUUX's boot PROM, or a program of `golden/src/quux.rs`.
        cmd += ["-GPROM_HEX=\"%s\""
                % os.path.join(args.goldens, spec["prom"])]
    elif spec.get("gprom"):
        cmd += ["-GPROM_HEX=\"%s\""
                % os.path.join(args.goldens, "boot_prom.hex")]
    cmd += ["-Mdir", obj, "--top-module", spec["top"]]
    cmd += tick_pkg(work)
    cmd += spec["sources"]
    # Everything the check builds that no mutation is aimed at: a wiring
    # harness, or a module with a check of its own.  `arty` has used the key
    # for that since it arrived; this is the same meaning in the one place
    # that builds rather than lints.
    cmd += spec.get("extra", [])
    cmd += [os.path.join(work, spec["tb"])]
    rc, out = run(cmd, work, build_env(args))
    if rc != 0:
        return BROKEN, first_problem(out)

    cmd = [os.path.join(obj, "V" + spec["top"])]
    for g in goldens_of(check):
        cmd.append(os.path.join(args.goldens, g))
    # The Makefile hands such a check two more paths: where to write its
    # patched PROM, and the unaltered one to build it from.
    if spec.get("gprom_path"):
        cmd.append(os.path.join(work, spec["gprom_path"]))
        cmd.append(os.path.join(args.goldens, "boot_prom.hex"))
    rc, out = run(cmd, work)
    if rc != 0:
        return CAUGHT, first_problem(out)
    return SURVIVED, out.strip().split("\n")[0]


def tcl_check(args, work, spec):
    """Run a Tcl harness in the mutant copy.  Exiting non-zero is caught.

    No build step, unlike everything else here: Tcl is read as it runs, so a
    mutation that is not valid Tcl shows up as the harness reporting the case
    that hit the bad line rather than as BROKEN.  That is a real difference
    from the fabric checks --- there, lint doing the catching is a failure of
    the mutation --- and it is written down rather than smoothed over.

    The harness resolves the script under test from its own directory, so
    running it out of the copy tests the copy's `boards/arty-z7-20/vivado/probe.tcl` and the
    working tree's is never read.
    """
    cmd = [args.tclsh, os.path.join(work, spec["tb"])]
    rc, out = run(cmd, work)
    if rc != 0:
        return CAUGHT, first_problem(out)
    for line in out.split("\n"):
        if line.startswith("ok:"):
            return SURVIVED, line.strip()
    return SURVIVED, out.strip().split("\n")[-1]


def arty_check(args, work, build_fails=False):
    """The top level, linted. Lint failing is the mutation being caught.

    SIX TIMES, BECAUSE THERE ARE SIX BOARDS, exactly as `build/arty.pass`
    runs it. `PROBE_DEPTH` and `DDR` are both zero by default and the generate
    blocks that instantiate `cadr_probe.sv`, `cadr_ps7.sv`, `cadr_axi_master.sv`,
    `cadr_axi_widen.sv` and `cadr_disk_pack.sv` are then not elaborated at all, so a lint of the
    default says nothing whatever about the two configurations the board is
    actually built in. A branch only one build reaches is a branch only one
    build checks --- and until the widening was pulled out into a module, that
    branch was where it lived.

    A CONFIGURATION WHOSE FILES ARE NOT IN THE COPY IS SKIPPED, and that is not
    tidiness either. `--since` names EARLIER revisions on purpose, and
    `boards/arty-z7-20/cadr_ps7.sv` arrives at b5542c5; a pass that verilated it
    unconditionally would report BROKEN for every arty record against anything
    older, which is the `git archive` pathspec lesson in a second place.
    """
    spec = CHECKS["arty"]
    prom = "-GPROM_HEX=\"%s\"" % os.path.join(args.goldens, "boot_prom.hex")
    base = [args.verilator, "--lint-only", "-Wall", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20", prom,
            "--top-module", spec["top"]]
    boards = [
        # The default board: the machine and nothing else.
        ([], ["tb/cadr_arty_stubs.sv"], []),
        # The instrumented one.
        (["-GPROBE_DEPTH=1024"], ["tb/cadr_arty_stubs.sv"],
         ["rtl/plumbing/cadr_probe.sv"]),
        # And the one with the processing system behind the memory port,
        # and the disk's pack side on the processing system's other two
        # ports.
        (["-GDDR=1"], ["tb/cadr_arty_stubs.sv", "tb/cadr_ps7_stub.sv"],
         ["boards/arty-z7-20/cadr_ps7.sv", "rtl/plumbing/cadr_axi_master.sv",
          "rtl/plumbing/cadr_axi_widen.sv", "rtl/plumbing/cadr_mem_count.sv",
          "rtl/plumbing/cadr_disk_pack.sv", "rtl/plumbing/cadr_console.sv",
          "rtl/plumbing/cadr_gp0_default.sv"] + GP0),
        # And the two the witness builds, which are branches only they
        # reach: nothing else elaborates `cadr_prove.sv` at all, and neither
        # of them elaborates the machine's own drive of the port.
        # A proving board brings GP0 out without the pack side, and answers
        # every address on it with the default slave.
        (["-GPROVE=1"], ["tb/cadr_arty_stubs.sv", "tb/cadr_ps7_stub.sv"],
         ["boards/arty-z7-20/cadr_ps7.sv", "rtl/plumbing/cadr_axi_master.sv",
          "rtl/plumbing/cadr_axi_widen.sv", "rtl/plumbing/cadr_mem_count.sv",
          "rtl/plumbing/cadr_prove.sv", "rtl/plumbing/cadr_gp0_default.sv",
          "rtl/plumbing/cadr_console.sv"] + GP0),
        (["-GPROVE=2"], ["tb/cadr_arty_stubs.sv", "tb/cadr_ps7_stub.sv"],
         ["boards/arty-z7-20/cadr_ps7.sv", "rtl/plumbing/cadr_axi_master.sv",
          "rtl/plumbing/cadr_axi_widen.sv", "rtl/plumbing/cadr_mem_count.sv",
          "rtl/plumbing/cadr_prove.sv", "rtl/plumbing/cadr_gp0_default.sv",
          "rtl/plumbing/cadr_console.sv"] + GP0),
        # And the sixth: the machine with the display output beside it,
        # which is the board a bitstream is actually built as.  `HDMI`
        # turns the port on by itself.  It is here rather than only in the
        # Makefile because `check_coverage` compares source LISTS, so a
        # runner exercising fewer configurations than the Makefile is
        # invisible to it --- which this project has already been through
        # once, with nothing between `cadr_axi_master` and `cadr_ps7`
        # checked by any tool while `make check` was green.
        (["-GDDR=1", "-GHDMI=1"], ["tb/cadr_arty_stubs.sv", "tb/cadr_ps7_stub.sv"],
         ["boards/arty-z7-20/cadr_ps7.sv", "rtl/plumbing/cadr_axi_master.sv",
          "rtl/plumbing/cadr_axi_widen.sv", "rtl/plumbing/cadr_mem_count.sv",
          "rtl/plumbing/cadr_disk_pack.sv", "rtl/plumbing/cadr_console.sv",
          "rtl/plumbing/cadr_gp0_default.sv"] + GP0 + DISPLAY),
    ]
    # **THE `USR_ACCESSE2` SHELL IS ADDED WHERE THE COPY HAS ONE, AND NOT
    # NAMED IN THE LISTS ABOVE.**  It arrives with the build stamp's readback;
    # a copy older than that instantiates no such primitive in any top level
    # and needs no shell for it.  Naming it beside `tb/cadr_arty_stubs.sv`
    # would put it in every configuration's `files`, so every configuration
    # would SKIP against an earlier revision and the check would report
    # `none of the board configurations could be linted` --- the `git archive`
    # pathspec lesson applied to one file rather than to a directory, and the
    # reason `--since` names earlier revisions on purpose.
    usr_access = [f for f in ["tb/cadr_usr_access_stub.sv"]
                  if os.path.exists(os.path.join(work, f))]
    ran = 0
    for generics, stubs, extra_sources in boards:
        files = stubs + extra_sources
        if not all(os.path.exists(os.path.join(work, f)) for f in files):
            continue
        cmd = base + generics + tick_pkg(work) + usr_access + stubs + spec["extra"] + spec["sources"]
        cmd += extra_sources
        rc, out = run(cmd, work)
        if rc != 0:
            # A lint finding is the catch; a mutant that does not compile is
            # not a verdict on the check.  See `lint_verdict`.
            return lint_verdict(out, build_fails)
        ran += 1
    if ran == 0:
        return BROKEN, "none of the board configurations could be linted"
    return SURVIVED, "lint passes on %d board configuration%s" % (
        ran, "" if ran == 1 else "s")


def script_check(args, work, spec):
    """Run a checking script over the mutated copy.  Refusing is being caught.

    The script reads the tree rather than building anything, so there is no
    build step to tell apart from a verdict: it either finds what it is
    looking for and agrees, or it does not.  A copy that predates the file
    the script reads is BROKEN rather than a survivor, for the reason
    `de25_check` gives about its own: a check that never saw the mutation has
    not caught it.
    """
    for f in spec["sources"]:
        if not os.path.exists(os.path.join(work, f)):
            return BROKEN, "%s is not in this copy" % f
    script = os.path.join(work, spec["cmd"][0])
    if not os.path.exists(script):
        return BROKEN, "%s is not in this copy" % spec["cmd"][0]
    rc, out = run([sys.executable, script] + list(spec["cmd"][1:]), work)
    if rc != 0:
        return CAUGHT, first_problem(out)
    return SURVIVED, "the script read the tree and agreed with it"


def de25_check(args, work, build_fails=False):
    """The DE25-Nano's top level, linted and then simulated, as
    `build/de25.pass` does both.

    Lint failing is the mutation being caught, and a mutant that does not
    compile is BROKEN, which `lint_verdict` decides exactly as it does for
    `arty`.  After the lints, the simulation failing is the mutation being
    caught, and its build failing is BROKEN.  The copy must have the board's files: `--since` names revisions
    older than this board, and there the check has nothing to lint.
    """
    spec = CHECKS["de25"]
    files = spec["stubs"] + spec["sources"]
    if not all(os.path.exists(os.path.join(work, f)) for f in files):
        return BROKEN, "the DE25-Nano's top level is not in this copy"
    prom = "-GPROM_HEX=\"%s\"" % os.path.join(args.goldens, "boot_prom.hex")
    sync = "-GSYNC_PROM_HEX=\"%s\"" % os.path.join(args.goldens, "sync_prom.hex")
    # **AND THE BOARD'S MAP OF THE PROCESSOR'S MEMORY, ON EVERY PASS**, as the
    # Makefile lints it: the top level refuses to elaborate without it, so a
    # lint that left it out would report every mutation as caught.
    cmd = [args.verilator, "--lint-only", "-Wall", "-Irtl/machine",
           "-Irtl/plumbing", "-DCADR_DDR_MAP_DE25_NANO", prom, sync,
           "--top-module", spec["top"]]
    cmd += spec["stubs"] + tick_pkg(work) + spec["extra"] + spec["sources"]
    rc, out = run(cmd, work)
    if rc != 0:
        return lint_verdict(out, build_fails)
    # And the probe's board, as `build/de25.pass` lints it second.  A copy
    # from before the probe reached this board has nothing to lint there.
    probe = spec["probe"]
    if not all(os.path.exists(os.path.join(work, f)) for f in probe):
        return SURVIVED, "lint passes on the one board configuration this copy has"
    rc, out = run(cmd[:6] + ["-GPROBE_DEPTH=1024"] + cmd[6:] + probe, work)
    if rc != 0:
        return lint_verdict(out, build_fails)
    # And the memory board, as `build/de25.pass` lints it third: the processor
    # in the design, which is a define and not a parameter because it changes
    # the top level's port list.
    ddr = spec["ddr"]
    if not all(os.path.exists(os.path.join(work, f)) for f in ddr):
        return SURVIVED, "lint passes on the two board configurations this copy has"
    rc, out = run(cmd[:6] + ["-DCADR_DE25_DDR"] + cmd[6:] + ddr, work)
    if rc != 0:
        return lint_verdict(out, build_fails)
    # And the display output, as `build/de25.pass` lints it fourth: the
    # second define, which adds the video bus and the transmitter's two wires
    # to the port list.
    hdmi = spec["hdmi"]
    if not all(os.path.exists(os.path.join(work, f)) for f in hdmi):
        return SURVIVED, "lint passes on the three board configurations this copy has"
    rc, out = run(cmd[:6] + ["-DCADR_DE25_DDR", "-DCADR_DE25_HDMI"] + cmd[6:] + ddr + hdmi,
                  work)
    if rc != 0:
        return lint_verdict(out, build_fails)
    # And the top level simulated, as `build/de25.pass` runs it last.  A copy
    # from before the simulation existed has only the lints to say anything.
    sim = spec["sim"] + [spec["sim_tb"]]
    if not all(os.path.exists(os.path.join(work, f)) for f in sim):
        return SURVIVED, "lint passes on all four board configurations"
    obj = os.path.join(work, "obj_de25_top")
    rc, out = run([args.verilator, "--cc", "--exe", "--build", "-Wall",
                   "--pins-inout-enables", "-O2", "-CFLAGS", "-O2",
                   "-Irtl/machine", "-Irtl/plumbing", "-DCADR_DDR_MAP_DE25_NANO",
                   "-DCADR_DE25_DDR", "-DCADR_DE25_HDMI", "-Mdir", obj,
                   "--top-module", "cadr_de25"]
                  + spec["sim"][:2] + tick_pkg(work) + spec["sim"][2:] + ddr + hdmi
                  + [os.path.join(work, spec["sim_tb"])], work, build_env(args))
    if rc != 0:
        return BROKEN, first_problem(out)
    rc, out = run([os.path.join(obj, "Vcadr_de25")], work)
    if rc != 0:
        return CAUGHT, first_problem(out)
    return SURVIVED, "lint passes on all four board configurations, and the simulation agrees"


def generator_check(args, work, spec):
    """Build the mutated generator and run it.  Refusing is being caught.

    Build and run are separate so that a mutation rustc rejects is BROKEN
    rather than caught --- the same distinction lint gives the fabric
    mutations, and for the same reason: a check that never saw the mutation
    has not caught it.

    EACH MUTATION GETS ITS OWN TARGET DIRECTORY, and this is not tidiness.
    Every mutant copy is a package called `golden` with a binary called
    `cables`, so against a shared target directory they all uplift to one
    `release/cables` and cargo will hand a later mutation the earlier one's
    binary.  Measured: three different mutations of cables.rs all panicked
    with the *same* message, which is one mutation's verdict reported three
    times.  It is the stale-binary trap `docs/mutations.md` names, in the
    mirror --- there it made mutations look like survivors, here it makes
    them look caught, and looking caught is worse because nothing is
    obviously wrong.
    Isolation costs 13 s and 14 MB a mutation and removes the whole class.
    """
    manifest = os.path.join(work, "golden", "Cargo.toml")
    env = {"CARGO_TARGET_DIR": os.path.join(work, "cargo-target")}
    common = ["--quiet", "--manifest-path", manifest,
              "--release", "--bin", spec["bin"]]
    rc, out = run([args.cargo, "build"] + common, work, env)
    if rc != 0:
        return BROKEN, first_problem(out)
    rc, out = run([args.cargo, "run"] + common, work, env)
    if rc != 0:
        return CAUGHT, panic_message(out)
    return SURVIVED, "the generator wrote its output without complaint"


def cables_check(args, work, build_fails=False):
    """The cables check is two targets, and it takes both to hold the claim.

    `cables.pass` is lint alone, which catches a wrong direction or a name
    that no longer exists.  It cannot catch a changed comment --- MIT's own
    name on the wire --- and what cadr_cables.svh holds to is both netlists
    via `part::pinout`.  Only `current` enforces that: it
    regenerates from muir and fails if anything moved.  So this does the same,
    against the copy, with plain diff standing in for `git diff`.
    """
    cmd = [args.verilator, "--lint-only", "-Wall",
           "--top-module", "cadr_cables_lint", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20",
           "rtl/machine/cadr_cables_lint.sv"]
    rc, out = run(cmd, work)
    if rc != 0:
        # The same lint-shaped path as `arty_check`: see `lint_verdict`.
        return lint_verdict(out, build_fails)

    # `current`, on the copy: keep what the mutation made, regenerate over it,
    # and see whether the generator disagrees.
    mutated = os.path.join(work, "mutated")
    if os.path.exists(mutated):
        shutil.rmtree(mutated)
    os.makedirs(mutated)
    for path in GENERATED:
        shutil.copy(os.path.join(work, path),
                    os.path.join(mutated, os.path.basename(path)))

    cmd = [args.cargo, "run", "--quiet", "--manifest-path",
           os.path.join(REPO, "golden", "Cargo.toml"), "--bin", "cables"]
    rc, out = run(cmd, work)
    if rc != 0:
        return BROKEN, "the generator failed: " + first_problem(out)

    for path in GENERATED:
        base = os.path.basename(path)
        if not filecmp.cmp(os.path.join(work, path),
                           os.path.join(mutated, base), shallow=False):
            return CAUGHT, "`current`: %s is not what the generator writes" % base
    return SURVIVED, "lint passes and the generator writes it unchanged"


def goldens_of(check):
    """The reference traces a check is handed, in the order it takes them.

    A check's `golden` is one file, a list of them, or `None`.  `unibus`
    takes two --- the card's decode and the bus interface's --- so that
    neither block's address set is its testbench's own transcription, and
    everything that looks a trace up goes through here rather than reading
    the key three different ways.
    """
    golden = CHECKS[check]["golden"]
    if not golden:
        return []
    return [golden] if isinstance(golden, str) else list(golden)


def check_coverage(mutations):
    """Sources a check builds that no mutation ever touches.

    The inverse of the `@file` validation, which catches a mutation naming a
    file its check does not build.  This catches the other direction --- a
    file the check builds that nothing is aimed at --- and that direction is
    the one that hides, because nothing about it is ever wrong: the run is
    green, the count is right, and a whole module is untested.
    """
    # The lint harness is generated, tied off and has no behavior; what
    # carries the port list is the header it includes, which is mutated.
    exempt = {"rtl/machine/cadr_cables_lint.sv"}
    touched = set(m.path for m in mutations)
    builds = set()
    for spec in CHECKS.values():
        builds |= set(spec["sources"])
    return ["%s is built by a check and no mutation touches it" % src
            for src in sorted(builds - touched - exempt)]


def check_makefile():
    """The Makefile is the other description of the six checks.

    Two descriptions of one thing drift.  This does not reimplement the
    Makefile --- it only asks that every source file this runner verilates is
    named in the rule that builds the same check, so a file added to a check
    there and not here shows up as a warning rather than as silent
    under-testing.
    """
    try:
        with open(os.path.join(REPO, "Makefile")) as f:
            text = f.read()
    except IOError:
        return ["Makefile is not readable"]
    missing = []
    # The direction that matters most, and the one nothing was watching: a
    # check the Makefile runs that this runner has never heard of is a check
    # with no mutations against it, and until it is named here there is
    # nothing anywhere to say so. `machine` was that for a while.
    # `ddr_map` is lint over constants only.  `readout_face` is the Linux
    # side of the readout window --- C under `boards/`, which this runner's
    # own copy does carry, so a record COULD be aimed at `readout.c` and none
    # is: what that check holds is the program's transport against a model,
    # and the property it exists for --- that a word whose echo is not the
    # address asked for is refused --- is already a deliberate failure in its
    # own model rather than a mutation of the source.  Naming it here rather
    # than aiming a record is the second of the two ways to close this
    # warning, and it is the one that stands alone.  `checkpoint` is the same
    # shape as `readout_face` and closed the same way, and the reason is worth
    # writing down rather than inherited: its DUT is a C program under
    # `boards/`, and its judge is muir's own reader.  It already carries
    # mutations --- three of them, in `chk_rtl.c` behind `CHK_MUTATE`, built
    # by its own Makefile and run by its own rule, with the catching line
    # asserted and the leg that caught each one named.  A record aimed at it
    # here would be a fourth mutation run by a different machinery against the
    # same file, and this runner has no way to build a C program three times
    # over and put muir behind it.  So it is named here, which is the one of
    # the two ways that stands alone.  `chaosnet`, `serial` and `terminal` are
    # the Linux halves of three of the I/O board's four cables, and they are
    # closed the third way --- which is neither of those two, and is worth
    # saying so rather than filing under one of them.  Each carries a mutation
    # list OF ITS OWN, in its own package, run by its own `mutate.py` from its
    # own `make check`: the same machinery cadr-disk-packs already uses, and
    # the same record format as `mutations/list.txt`.  So something does
    # mutate them and this runner is not it, because this runner verilates
    # SystemVerilog and those checks are C programs with a socket and a
    # scratch directory behind them.  A record aimed here would have to build
    # a C program a second way; the package's own runner already builds each
    # mutant in a directory of its own and calls a build failure BROKEN, which
    # is the property that matters.
    #
    # **`terminal` IS NEW HERE AND THE CHECK IT NAMES IS OLDER THAN THE
    # ENTRY.**  `cadr-terminal` has had `make -C src check` since it was
    # written, and nothing in the top-level `make check` ran it until the
    # keyboard slice --- so for as long as it was only a screen, the 420
    # checks and fifteen mutations it carries were run by whoever remembered.
    # That is the hole this line and the Makefile's `terminal.pass` close
    # together, and the pair had to land in one commit: a `.pass` added
    # without the name here warns, and a name here without the `.pass` says
    # nothing about a check nobody runs.
    # `fpgarc` is shell: one file of flags on the card, five init scripts, and
    # each program handed the lines of the flags it owns.  mutate.py compiles
    # C, so a record naming a shell script would be BROKEN by construction and
    # a record aimed at a check this runner has no entry for kills the run at
    # parse for every record.  Naming it here is the way that stands alone.
    # `cora` is the Cora Z7-07S's lint, the same five board configurations
    # `arty` lints one board along, and it is named here rather than given
    # records of its own.  What `arty`'s records hold is that a top level
    # which leaves one of `cadr_machine`'s outputs unconnected, or brings a
    # PS7 pin out and wires it to nothing, is caught --- and that property is
    # about the SHAPE of a board's top level, not about which board it is.
    # `boards/cora-z7-07s/cadr_cora.sv` is `boards/arty-z7-20/cadr_arty.sv`
    # with this board's pins on it, so a record aimed here would be the same
    # mutation of the same text in a second file: it would tell us nothing
    # `arty` does not already tell us, and it would have to be kept in step
    # with the Arty's by hand for ever.  Naming it here is the second of the
    # two ways to close this warning and the one that stands alone.
    # `de25_pins` is Python reading a Tcl pin file and, when one is named,
    # Terasic's Quartus settings.  Nothing in it is verilated, and the second
    # of the two files it compares cannot be carried into a mutation work
    # tree, so it is named here and given no records.  `de25_linux` is the
    # DE25-Nano's Linux side: Python over the pinned sources' hash files, and
    # the board programs compiled with that board's address map.  C, like
    # `chaosnet`'s, and what bites on the code it compiles is the packages'
    # own mutation lists; named here for the same reason.
    # `board_reset` is one `.pass` and three builds, one a board, and each
    # build is its own entry above, `board_reset_arty` and the other two.
    # `fault` is the same shape: `fault_arty`, `fault_cora` and `fault_de25`.
    known = set(CHECKS) | {"board_reset", "fault", "ddr_map", "readout_face", "checkpoint",
                           "chaosnet", "serial", "terminal", "console_face",
                           "usb_input", "fpgarc", "cora",
                           "de25_pins", "de25_linux"}
    # **AND THE NAME PATTERN TAKES DIGITS, WHICH IT DID NOT.**  It was
    # `[a-z_]+`, so a check whose name has a digit in it was invisible to this
    # guard in both directions --- neither warned about nor checked.  Four
    # names in the Makefile have one: `gp0_default`, `gp0_split` and
    # `gp1_split`, all three of which have entries in `CHECKS` and were simply
    # never being looked at.  A guard that cannot see a whole class of name is
    # the shape of failure this file is full of.
    # **AND QUUX'S CHECKS, WHICH THE PATTERN ABOVE COULD NOT SEE.**  A QUUX
    # check is `<name>.quux.pass`, which is this runner's `<name>_quux`, and
    # the programs of `golden/src/quux.rs` are pattern rules over the
    # Makefile's `QUUX_PROGRAMS`, so each program is two checks by name.
    names = set(re.findall(r"\$\(BUILD\)/([a-z0-9_]+)\.pass", text))
    names |= set(n + "_quux" for n in
                 re.findall(r"\$\(BUILD\)/([a-z0-9_]+)\.quux\.(?:\$\(QKL?1?\)\.)?pass", text))
    programs = re.search(r"^QUUX_PROGRAMS := (.*)$", text, re.M)
    for prog in (programs.group(1).split() if programs else []):
        names |= {"quux_" + prog}
    # QUUX runs its own list at its synchronous microcycle (`ticksync` for
    # `tick`), so a program's QUUX check is named from that one.
    programs = re.search(r"^QUUX_SYNC_PROGRAMS := (.*)$", text, re.M)
    for prog in (programs.group(1).split() if programs else []):
        names |= {"quux_" + prog + "_quux"}
    # And the programs QUUX also runs at an L of one, `<program>_quux_l1`.
    programs = re.search(r"^QUUX_L1_PROGRAMS := (.*)$", text, re.M)
    for prog in (programs.group(1).split() if programs else []):
        names |= {"quux_" + prog + "_quux_l1"}
    for found in sorted(names):
        if found not in known:
            missing.append("the Makefile runs `%s` and nothing here mutates it"
                           % found)
    for check, spec in sorted(CHECKS.items()):
        # A generator is run by a phony target --- `make cables` has no
        # prerequisites to name and does not need them, being always out of
        # date --- so there is nothing here for this to compare against.
        if spec.get("kind") == "generator":
            continue
        for src in spec["sources"] + spec.get("extra", []):
            if src not in text:
                missing.append("%s: the Makefile does not mention %s"
                               % (check, src))
    return missing


def cannot_be_caught(check):
    """A record for a mutation no check can catch, built from the source.

    Two arms want a mutation that survives --- "a survivor with nothing
    recorded", which must fail the run, and "a hole that is still open",
    which must not.  Taking one from list.txt means taking whichever record
    carries an `@hole`, and there is meant to come a day when none does.

    A comment cannot change what the fabric does, so a comment-only change
    survives by construction, whatever the list holds.  The line is found in
    the source rather than written here, so this does not rot when the
    comment does: any comment line that occurs exactly once will do.
    """
    path = CHECKS[check]["sources"][0]
    with open(os.path.join(REPO, path)) as f:
        lines = f.read().split("\n")
    seen = {}
    for line in lines:
        seen[line] = seen.get(line, 0) + 1
    for line in lines:
        if line.strip().startswith("//") and seen[line] == 1:
            return ("@mutation self-test-a-comment-changed\n"
                    "@check %s\n"
                    "@file %s\n"
                    "@note Built by --self-test, not taken from the list: a\n"
                    "@note comment cannot change what the fabric does, so this\n"
                    "@note survives every check by construction and does not\n"
                    "@note depend on the list still holding an open hole.\n"
                    "@old\n%s\n@new\n%s  // and the self-test was here\n@end\n"
                    % (check, path, line, line))
    die("%s has no comment line of its own for --self-test to change" % path)


def self_test(args):
    """The runner's own guarantees, run against lists written to fail.

    Everything here is about the runner rather than about the fabric, and
    every case is one that was got wrong once or would have been: a mutation
    that does not apply, one lint rejects, a survivor with nothing recorded, a
    hole that has closed, and --- the one that got past review --- a run from
    a directory that is not the repository root with relative paths, where the
    runner's own chdir made every relative path resolve against the copy.

    Most fixtures are derived from list.txt rather than written out here, so
    they do not rot when a record moves.  What makes that sound is that a
    green run is the precondition: every record without an `@hole` is caught,
    so putting one on must give CLOSED.

    The two arms that need a mutation which *survives* are built instead ---
    see `cannot_be_caught`.  Deriving those from the list would mean
    borrowing whichever record happens to carry an `@hole`, and the list is
    meant to run out of those: every hole closed is a check fixed.  A fixture
    that stops working when the project succeeds is the wrong fixture.
    """
    mutations = parse(args.list)
    with open(args.list) as f:
        text = f.read()

    def record(m):
        """One record's text, sliced out of the list by name."""
        start = text.index("@mutation " + m.name + "\n")
        return text[start:text.index("\n@end\n", start) + len("\n@end\n")]

    plain = [m for m in mutations if not m.hole]
    if not plain:
        die("--self-test wants at least one record without an @hole")
    # Each case runs as the run itself would, through ccache when it does.
    cached = ["--ccache", args.ccache, "--ccache-size", args.ccache_size] \
        if args.ccache else []
    # The cheapest check to build, so the cases cost two builds each --- and
    # one that VERILATES, so that "a mutation lint rejects" has a build to
    # reject it. A generator would cost a cargo build and its "not verilog at
    # all" fixture would be a rustc error rather than a lint one, a less
    # faithful stand-in for the case being covered; `kind: tcl` has no build at
    # all, so that arm would have nothing to test. Both are excluded here.
    # And not a lint-only check either: there "does not build" and "caught"
    # were once the same exit status, and the arm below is what tells them
    # apart now; this arm wants a check whose build is a step of its own.
    fabric = [m for m in plain
              if CHECKS[m.check].get("kind") not in ("generator", "tcl", "lint")]
    if not fabric:
        die("--self-test wants at least one mutation of the fabric")
    cheap = min(fabric, key=lambda m: len(CHECKS[m.check]["sources"]))
    # A lint-only check, for the arm that plants a mutant which does not
    # compile where the check IS lint.  Measured at the request path's slice:
    # a `@new` with a dangling comma was reported CAUGHT, because lint failing
    # and lint refusing to parse are one exit status.  `arty` is the one such
    # check; the fixture is derived from whichever of its records comes
    # first, so it does not rot when a record moves.
    linted = [m for m in plain if CHECKS[m.check].get("kind") == "lint"]

    unappliable = record(cheap).replace(
        "@old\n", "@old\n  this line is not in the file\n", 1)
    unbuildable = re.sub(r"@new\n.*?@end", "@new\n  not verilog at all\n@end",
                         record(cheap), flags=re.S)
    # The same mutant --- a dangling brace, the shape that was reported
    # caught --- aimed at a check that is lint.
    unparseable = (re.sub(r"@new\n.*?@end", "@new\n  };\n@end",
                          record(linted[0]), flags=re.S) if linted else None)
    # After the @mutation line, not before it: a field ahead of the record it
    # belongs to is outside every record, which the parser rightly refuses.
    head, rest = record(cheap).split("\n", 1)
    closed = head + "\n@hole #99999\n" + rest
    # Built, not borrowed: independent of what the list happens to hold.
    survived = cannot_be_caught(cheap.check)
    still_open = survived.replace("@check ", "@hole #99999\n@check ", 1)

    root = os.path.join(args.work, "selftest")
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)

    cases = [
        ("a mutation that does not apply", unappliable, 1, "DID NOT APPLY"),
        ("a mutation lint rejects", unbuildable, 1, "DID NOT BUILD"),
    ] + ([("a lint-only mutant that does not parse", unparseable, 1,
           "DID NOT BUILD")] if unparseable else []) + [
        ("a survivor with nothing recorded", survived, 1, "SURVIVED"),
        ("a hole that has closed", closed, 1, "A HOLE THAT CLOSED"),
        ("a hole that is still open", still_open, 0, "known hole"),
    ]

    bad = 0
    for i, (what, body, want_rc, want_text) in enumerate(cases):
        path = os.path.join(root, "case%d.txt" % i)
        with open(path, "w") as f:
            f.write("# generated by --self-test\n\n" + body)
        cmd = [sys.executable, os.path.abspath(__file__),
               "--goldens", args.goldens,
               "--work", os.path.join(root, "case%d" % i),
               "--list", path, "--jobs", "2",
               "--verilator", args.verilator, "--cargo", args.cargo,
               "--tclsh", args.tclsh] + cached
        rc, out = run(cmd, REPO)
        ok = (rc != 0) == (want_rc != 0) and want_text in out
        sys.stdout.write("  %-34s %s\n" % (what, "ok" if ok else "FAILED"))
        if not ok:
            sys.stdout.write("      wanted exit %s and %r, got exit %d\n"
                             % ("non-zero" if want_rc else "zero",
                                want_text, rc))
            sys.stdout.write("".join("      | %s\n" % s
                                     for s in out.strip().split("\n")[-12:]))
            bad += 1

    # Two generator mutations must not report the same failure. They are
    # separate packages all called `golden`, all building a binary of the
    # same name, so against one target directory cargo hands the second
    # mutation the first one's binary and both are reported caught --- on one
    # mutation's evidence, twice. That happened, and nothing about the report
    # looked wrong. `@hole` on both is what makes the runner print each
    # detail: they come back as CLOSED, which is a failure and prints why.
    gens = [m for m in mutations if CHECKS[m.check].get("kind") == "generator"]
    if len(gens) >= 2:
        body = []
        for m in gens[:2]:
            head, rest = record(m).split("\n", 1)
            body.append(head + "\n@hole #99999\n" + rest)
        path = os.path.join(root, "generators.txt")
        with open(path, "w") as f:
            f.write("# generated by --self-test\n\n" + "\n".join(body))
        cmd = [sys.executable, os.path.abspath(__file__),
               "--goldens", args.goldens,
               "--work", os.path.join(root, "generators"),
               "--list", path, "--jobs", "2",
               "--verilator", args.verilator, "--cargo", args.cargo,
               "--tclsh", args.tclsh] + cached
        rc, out = run(cmd, REPO)
        reasons = set(l.strip() for l in out.split("\n") if "assertion" in l)
        ok = rc != 0 and "A HOLE THAT CLOSED" in out and len(reasons) >= 2
        sys.stdout.write("  %-34s %s\n"
                         % ("generators do not share a binary",
                            "ok" if ok else "FAILED"))
        if not ok:
            sys.stdout.write("      %d distinct failures from %d mutations; "
                             "want one each\n" % (len(reasons), len(gens[:2])))
            sys.stdout.write("".join("      | %s\n" % r for r in sorted(reasons)))
            bad += 1

    # `--since` against the same revision must find nothing. The dangerous
    # failure of that flag is the false positive --- calling a check weaker
    # when nothing changed sends someone to diff two commits for a
    # difference that is not there, and a regression detector that cries
    # wolf is worse than none. The true positive is not tested here: it
    # needs two revisions whose verdicts differ, which cannot be built out
    # of the list.
    if gens or plain:
        holed = [m for m in mutations if m.hole]
        if holed:
            path = os.path.join(root, "since.txt")
            with open(path, "w") as f:
                f.write("# generated by --self-test\n\n" + record(holed[0]))
            here_rev = subprocess.run(
                ["git", "-C", REPO, "rev-parse", "HEAD"],
                stdout=subprocess.PIPE).stdout.decode().strip()
            cmd = [sys.executable, os.path.abspath(__file__),
                   "--goldens", args.goldens,
                   "--work", os.path.join(root, "since"),
                   "--list", path, "--jobs", "2",
                   "--rev", here_rev, "--since", here_rev,
                   "--verilator", args.verilator, "--cargo", args.cargo,
                   "--tclsh", args.tclsh] + cached
            rc, out = run(cmd, REPO)
            ok = "A CHECK THAT GOT WEAKER" not in out and "not caught there" in out
            sys.stdout.write("  %-34s %s\n"
                             % ("--since against the same revision",
                                "ok" if ok else "FAILED"))
            if not ok:
                sys.stdout.write("".join("      | %s\n" % l
                                         for l in out.strip().split("\n")[-10:]))
                bad += 1

    # The case that got past review. Relative --goldens and --work, from a
    # directory that is not the repository root: the runner chdirs into each
    # mutant copy to build it, so anything not resolved up front resolves
    # against the copy. `make mutants` from the repo root is this invocation.
    here = os.path.join(root, "relative")
    os.makedirs(os.path.join(here, "work"))
    # The PROM images as well as the traces: every check is handed
    # `sync_prom.hex`, and without it this case died on a missing file.
    for name in os.listdir(args.goldens):
        if name.endswith((".golden", ".hex")):
            shutil.copy(os.path.join(args.goldens, name),
                        os.path.join(here, name))
    cmd = [sys.executable, os.path.abspath(__file__),
           "--goldens", ".", "--work", "work",
           "--list", os.path.relpath(args.list, here),
           "--only", cheap.name, "--jobs", "2",
           "--verilator", args.verilator, "--cargo", args.cargo,
           "--tclsh", args.tclsh]
    if args.ccache:
        cmd += ["--ccache", os.path.relpath(args.ccache, here),
                "--ccache-size", args.ccache_size]
    rc, out = run(cmd, here)
    ok = rc == 0 and "ok: every mutation was caught" in out
    sys.stdout.write("  %-34s %s\n"
                     % ("relative paths, another cwd", "ok" if ok else "FAILED"))
    if not ok:
        sys.stdout.write("".join("      | %s\n" % s
                                 for s in out.strip().split("\n")[-12:]))
        bad += 1

    if bad:
        sys.stdout.write("\n%d of the runner's own guarantees do not hold\n"
                         % bad)
        return 1
    sys.stdout.write("\nok: the runner reports what it is supposed to\n")
    return 0


def main():
    ap = argparse.ArgumentParser(description="mutation-test the checks")
    ap.add_argument("--goldens", required=True,
                    help="directory holding the reference traces")
    ap.add_argument("--work", required=True,
                    help="where the per-mutation copies go")
    ap.add_argument("--verilator", default="verilator")
    ap.add_argument("--cargo", default="cargo")
    ap.add_argument("--tclsh", default="tclsh")
    ap.add_argument("--jobs", type=int, default=0,
                    help="parallel mutations (default: one per cpu)")
    ap.add_argument("--only", default=None,
                    help="run only mutations whose name or check contains this")
    # Not for everyday use: `make mutants` runs list.txt. It is here so that
    # the runner's own guarantees --- a mutation that does not apply, and one
    # lint rejects, are loud --- can be demonstrated against a list written to
    # fail, rather than only asserted in a comment.
    ap.add_argument("--list", default=LIST, help="a list other than list.txt")
    ap.add_argument("--since", default=None,
                    help="re-run whatever is not caught against this earlier "
                         "revision; anything caught there is a check that has "
                         "got weaker, not a hole")
    ap.add_argument("--rev", default=None,
                    help="mutate this commit's sources rather than the files "
                         "on disk; use it whenever anyone else may be editing")
    ap.add_argument("--machine", default=None, choices=["cadr", "quux"],
                    help="run only the records aimed at checks of this machine; "
                         "both when not given")
    ap.add_argument("--self-test", action="store_true",
                    help="check the runner's own guarantees, not the fabric")
    ap.add_argument("--ccache", default=None, metavar="DIR",
                    help="compile the Verilator builds through ccache, with "
                         "its cache in DIR")
    ap.add_argument("--ccache-size", default="10G",
                    help="the most the ccache directory may hold")
    args = ap.parse_args()

    # Every check is built and run with its working directory set to the
    # mutant's own copy, so a relative path given on the command line would
    # resolve against that copy rather than against where the caller stood:
    # `--work build/mutants` becomes build/mutants/<name>/build/mutants/...
    # and Verilator cannot write there, and `--goldens build` is looked for
    # under the copy and is not there. Resolved here, once, against the
    # directory the caller was actually in.
    #
    # Same reason the Makefile writes `$(abspath tb/cadr_phase_gen_tb.cpp)`,
    # and af70da4 is where that was learned. The difference is that this has
    # to hold however the runner is invoked and not only when the caller
    # remembers, which is why it is here and not only in the rule.
    args.goldens = os.path.abspath(args.goldens)
    args.work = os.path.abspath(args.work)
    args.list = os.path.abspath(args.list)
    if args.ccache:
        args.ccache = os.path.abspath(args.ccache)
        # Without the program every build would fail and every record read
        # BROKEN; say what is missing once instead.
        if shutil.which("ccache") is None:
            die("--ccache: there is no ccache on the PATH")

    if args.jobs <= 0:
        # Half the cpus, not all of them, and the reason is memory rather
        # than politeness about cpu: a job is a Verilator -O2 build of a
        # 1,262-line module, and enough of them at once will have the kernel
        # kill something. It has --- another session's task, on a machine
        # with 14 GB and three of us building. Wall-clock barely moves,
        # because the runs are not all builds. `or 4`: cpu_count() answers
        # None where it cannot tell.
        args.jobs = max(2, (os.cpu_count() or 4) // 2)

    if args.self_test:
        sys.stdout.write("the runner's own guarantees:\n")
        return self_test(args)

    mutations = parse(args.list)
    # Kept before `--only` narrows it: coverage is a property of the list,
    # and warning that a file has no mutation because this run asked for a
    # different check would be noise on every filtered run.
    everything = list(mutations)
    if args.machine:
        # Which machine a check holds: its `machine`, the CADR's if unsaid.
        mutations = [m for m in mutations
                     if CHECKS[m.check].get("machine", "cadr") == args.machine]
        if not mutations:
            die("--machine %s matches nothing" % args.machine)
    if args.only:
        mutations = [m for m in mutations
                     if args.only in m.name or args.only in m.check]
        if not mutations:
            die("--only %s matches nothing" % args.only)

    if args.rev:
        sys.stdout.write("sources: %s\n" % args.rev)
    else:
        dirty = subprocess.run(
            ["git", "-C", REPO, "status", "--porcelain", "--", "rtl", "tb",
             "boards", "golden"],
            stdout=subprocess.PIPE).stdout.decode("utf-8", "replace")
        if dirty.strip():
            sys.stdout.write(
                "sources: the working tree, and it is not clean --- these "
                "results are\n         of whatever it holds right now:\n%s"
                % "".join("         %s\n" % l for l in dirty.strip().split("\n")))

    for warning in check_makefile() + check_coverage(everything):
        sys.stderr.write("mutations: warning: %s\n" % warning)

    # Only the checks that have mutations against them, so `--only` does not
    # pay for the rest.
    wanted = sorted(set(m.check for m in mutations))
    for check in wanted:
        for golden in goldens_of(check):
            if not os.path.exists(os.path.join(args.goldens, golden)):
                die("%s: no such trace; `make %s/%s` first"
                    % (os.path.join(args.goldens, golden), args.goldens, golden))

    if not os.path.exists(args.work):
        os.makedirs(args.work)

    # The baseline.  A check that was already failing would call every
    # mutation caught, so nothing runs until the unmutated copy is clean.
    sys.stdout.write("baseline, on an unmutated copy:\n")
    base = os.path.join(args.work, "baseline")
    generators = any(CHECKS[c].get("kind") == "generator" for c in wanted)
    if generators:
        muir_beside(args.work)
    copy_tree(base, with_golden=any(needs_golden(c) for c in wanted), rev=args.rev)
    baseline_bad = False
    # How long each check took here, which is what the records are ordered by.
    took = {}

    def timed(check):
        start = time.time()
        result = build_and_run(args, base, check)
        took[check] = time.time() - start
        return result

    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = dict((pool.submit(timed, c), c) for c in wanted)
        for f in concurrent.futures.as_completed(futures):
            check = futures[f]
            verdict, detail = f.result()
            # SURVIVED here means the check passed on unmutated source, which
            # is what it is supposed to do.
            ok = verdict == SURVIVED
            sys.stdout.write("  %-14s %s\n"
                             % (check, "ok" if ok else "FAILED: " + detail))
            baseline_bad = baseline_bad or not ok
    if baseline_bad:
        sys.stderr.write(
            "\nmutations: the baseline does not pass, so nothing was run.\n"
            "  Fix the checks first: a mutation `caught` by a check that was\n"
            "  already failing is caught by nothing.\n")
        return 2
    sys.stdout.write("\n")

    def one(m):
        work = os.path.join(args.work, m.name)
        copy_tree(work, with_golden=needs_golden(m.check), rev=args.rev)
        problem = apply(work, m, args.list)
        if problem:
            m.verdict, m.detail = UNAPPLIED, problem
            return m
        m.verdict, m.detail = build_and_run(args, work, m.check, m.build_fails)
        # `@hole` says the check is known not to catch this and names the
        # issue.  It turns a survivor into a recorded exception --- and a
        # mutation that IS caught while still carrying one into a failure,
        # because a hole that closed and was never noticed is how a recorded
        # exception rots into a suppressed finding.
        if m.hole:
            if m.verdict == SURVIVED:
                m.verdict = HOLE
            elif m.verdict == CAUGHT:
                m.verdict = CLOSED
        # A survivor is a finding, and the first question about it is whether
        # anything else would have caught it.  Only survivors pay for this.
        if m.verdict in (SURVIVED, HOLE):
            for other in sorted(CHECKS):
                if other == m.check or m.path not in CHECKS[other]["sources"]:
                    continue
                if any(not os.path.exists(os.path.join(args.goldens, g))
                       for g in goldens_of(other)):
                    continue
                verdict, _ = build_and_run(args, work, other)
                if verdict == SURVIVED:
                    m.also.append(other)
        return m

    # THE LONGEST RECORDS GO FIRST, so that the run does not end on a few of
    # them with every other job idle.  A record carrying `@hole` goes ahead
    # of everything: it is expected to survive, and a survivor then runs
    # every other check that builds its file, one after another.  The rest
    # are ordered by what their check's baseline took a moment ago on this
    # machine, so there is no table of costs to keep in step with the checks.
    # Only the order changes: every record still runs its own check, and the
    # report is in list order.
    order = sorted(mutations,
                   key=lambda m: (m.hole is None, -took.get(m.check, 0)))
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        done = 0
        for m in pool.map(one, order):
            done += 1
            mark = {CAUGHT: ".", HOLE: "h", SURVIVED: "S",
                    CLOSED: "C", BROKEN: "B", UNAPPLIED: "U"}[m.verdict]
            sys.stdout.write(mark)
            sys.stdout.flush()
        sys.stdout.write("\n\n")

    # `--since`: a mutation that is not caught now may have been caught
    # before, and that is a different thing from a hole --- it is a check
    # that has got weaker. Only what is already not caught is re-run, so this
    # costs a pass over the survivors rather than over the list.
    #
    # HOLES ARE INCLUDED, and that is the point rather than an extra. A
    # recorded exception is exactly where a regression would hide: the run
    # stays green, the record says "known", and nothing asks whether it was
    # always known. The one time this has happened the mutation carried no
    # `@hole`, and it was luck.
    if args.since:
        suspects = [m for m in mutations if m.verdict in (SURVIVED, HOLE)]
        if suspects:
            sys.stdout.write("against %s, what is not caught now:\n"
                             % args.since)

            def before(m):
                work = os.path.join(args.work, "since", m.name)
                copy_tree(work, with_golden=needs_golden(m.check), rev=args.since)
                if apply(work, m, args.list) is None:
                    verdict, _ = build_and_run(args, work, m.check)
                    if verdict == CAUGHT:
                        m.was_caught_at = args.since
                return m

            with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
                for m in pool.map(before, suspects):
                    sys.stdout.write(
                        "  %-52s %s\n"
                        % (m.name[:52],
                           "CAUGHT THERE" if m.was_caught_at else "not caught there"))
            sys.stdout.write("\n")

    return report(mutations, args.list)


def report(mutations, listing_path):
    """The table, the known holes, and what failed.

    The exit rule is three-way, and the third part is what keeps `@hole`
    honest.  A survivor with no `@hole` fails: it is a new finding.  A
    survivor with one is reported and tolerated: it is a recorded exception,
    the same shape as the divergences from muir that are written down.
    And a mutation that is *caught* while still carrying an `@hole` fails too,
    because the hole has closed and the record has not caught up --- without
    that, suppressions accumulate silently and the list ends up carrying
    `@hole`s for holes that shut long ago.
    """
    counts = {}
    for m in mutations:
        row = counts.setdefault(m.check, dict((v, 0) for v in VERDICTS))
        row[m.verdict] += 1

    head = "  %-14s %9s %6s %5s %8s %6s %6s %9s\n"
    body = "  %-14s %9d %6d %5d %8d %6d %6d %9d\n"
    sys.stdout.write(head % ("check", "mutations", "caught", "holes",
                             "survived", "closed", "broken", "unapplied"))
    total = dict((v, 0) for v in VERDICTS)
    for check in sorted(counts) + ["total"]:
        if check == "total":
            row = total
        else:
            row = counts[check]
            for k in total:
                total[k] += row[k]
        sys.stdout.write(body % ((check, sum(row.values()))
                                 + tuple(row[v] for v in VERDICTS)))

    # Prominent, not a footnote: someone running this sees what is knowingly
    # not caught without going looking for it.
    holes = [m for m in mutations if m.verdict == HOLE]
    # Sorted by issue rather than by where they fall in the list, so the
    # summary line reads as a set of issues to go and look at.
    issues = " ".join(sorted(set(m.hole for m in holes),
                             key=lambda h: int(h[1:])))
    if holes:
        sys.stdout.write("\n  %d known hole%s, held open by %s\n"
                         % (len(holes), "" if len(holes) == 1 else "s",
                            issues))

    def listing(group, heading, why):
        if not group:
            return
        sys.stdout.write("\n%s\n  %s\n\n" % (heading, why))
        for m in group:
            sys.stdout.write("  %s  (%s, %s)\n" % (m.name, m.check, m.path))
            for note in m.notes:
                sys.stdout.write("      %s\n" % note)
            sys.stdout.write("      %s\n" % m.detail)
            if m.also:
                sys.stdout.write("      not caught by %s either\n"
                                 % ", ".join(m.also))

    listing(holes, "KNOWN HOLES, each held open by an issue",
            "The check does not catch these and it is written down. They stay\n"
            "  in the list --- a survivor quietly dropped is a check that\n"
            "  silently got weaker --- and they do not fail the run, so that a\n"
            "  new one can still be seen.\n"
            "\n"
            "  If one of these issues has been CLOSED, come back to its record:\n"
            "  nothing here can see that, and a hole whose question was answered\n"
            "  leaves an @hole suppressing nothing.")

    for verdict, heading, why in (
        (UNAPPLIED, "DID NOT APPLY",
         "The source moved under the list.  Nothing was tested; these are not\n"
         "  survivors and not caught.  Fix the @old text."),
        (BROKEN, "DID NOT BUILD",
         "Lint rejected the mutation, so the check never saw it.  Rewrite it\n"
         "  to keep every signal used, or lint is doing the catching."),
        (SURVIVED, "SURVIVED",
         "A hole in a check: the design is wrong and the check says it is\n"
         "  fine.  This belongs in the check, not in the list.  If it cannot be\n"
         "  fixed now, file it and record the issue with @hole."),
    ):
        listing([m for m in mutations if m.verdict == verdict], heading, why)

    weaker = [m for m in mutations if m.was_caught_at]
    if weaker:
        sys.stdout.write(
            "\nA CHECK THAT GOT WEAKER\n"
            "  These are caught at an earlier revision and not now. That is\n"
            "  not a hole --- a hole is a weakness with a reason --- it is a\n"
            "  check that could see something and cannot. Look at what changed\n"
            "  between the two revisions named.\n\n")
        for m in weaker:
            sys.stdout.write("  %s  (%s, %s)\n" % (m.name, m.check, m.path))
            sys.stdout.write("      caught at %s; here it %s\n"
                             % (m.was_caught_at,
                                "is held open as a hole, which it did not need"
                                if m.verdict == HOLE else "survives"))
            sys.stdout.write("      %s\n" % m.detail)

    closed = [m for m in mutations if m.verdict == CLOSED]
    if closed:
        sys.stdout.write(
            "\nA HOLE THAT CLOSED\n"
            "  The check catches this now and the record still says it does\n"
            "  not. Close the issue and delete the @hole line --- a suppression\n"
            "  nobody removes is how this mechanism would rot into a lie.\n\n")
        for m in closed:
            sys.stdout.write("  %s  (%s, %s)\n" % (m.name, m.check, m.path))
            sys.stdout.write("      close %s, and delete `@hole %s` at %s:%d\n"
                             % (m.hole, m.hole, listing_path, m.hole_line))
            sys.stdout.write("      %s\n" % m.detail)

    failed = (total[SURVIVED] + total[CLOSED] + total[BROKEN]
              + total[UNAPPLIED] + len(weaker))
    if failed:
        return 1
    if total[HOLE]:
        sys.stdout.write("\nok: %d mutations caught, %d known hole%s (%s)\n"
                         % (total[CAUGHT], total[HOLE],
                            "" if total[HOLE] == 1 else "s", issues))
    else:
        sys.stdout.write("\nok: every mutation was caught by its check\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
