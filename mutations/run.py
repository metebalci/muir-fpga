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
# that were really made --- CLAUDE.md's "What went wrong, and what caught it"
# is the seed of the list, because each of those passed something before it
# was found.
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
#   the build failed.  This is CLAUDE.md's own lesson, from the other side:
#   two mutations were once reported as surviving when lint had rejected them
#   and a stale binary ran.  Nothing here reuses a build directory, and a
#   build that fails is reported as BROKEN rather than as anything else.
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
# exception --- the same shape as CLAUDE.md's "Where the fabric parts from
# muir", or the testbench not comparing -TPR60 while RESET is high.  What the
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
        "golden": "tv.golden",
    },
    "axi_master": {
        # No muir reference, so no trace: the testbench is the stimulus.
        "sources": ["rtl/plumbing/cadr_axi_master.sv"],
        "top": "cadr_axi_master",
        "tb": "tb/cadr_axi_master_tb.cpp",
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
    "microcycle_sys": {
        "sources": ["rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv"],
        "top": "cadr_microcycle",
        "tb": "tb/cadr_microcycle_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": "rtl_sys.golden",
        "files": [("boot_prom.hex", "build/boot_prom.hex")],
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
    # boundary, against a control run that drives none.  It is NOT in `make
    # check` and it does not pass, because the defect it names is real and
    # unfixed; no record may be aimed at it until it does, a mutation
    # "caught" by a check that was already failing being caught by nothing.
    # It is named here so that `check_makefile` knows the target the Makefile
    # carries, and so that the record has somewhere to go on the day the fix
    # lands.
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
    "machine": {
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
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": "rtl.golden",
        "gprom": True,
    },
    # The machine behind real memory, which is what `DDR=1` puts on the part.
    # Same module list as `machine` and a different question: `machine` asks
    # whether the fabric agrees with muir, and this asks what it does where
    # muir cannot follow it --- past microcycle 537,900, where muir's modelled
    # disk controller answers the boot PROM's polls and the board's does not
    # exist.  Its reference is the boot PROM's own page-0 parity loop with a
    # poison in it and a modelled DDR3 that answers at a delay of its own.
    #
    # No `golden`: there is no trace to hand it.  The testbench runs the
    # machine twice from reset, 200 ms of machine time each way, and takes
    # about fifteen seconds --- the slowest check here that is not a trace.
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
            "rtl/plumbing/xilinx7/cadr_probe.sv", "tb/cadr_probe_harness.sv",
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
    # `sources` is the script, because the script is what the mutations are
    # aimed at.  The model and the harness are the check, not the thing
    # checked, and mutating them would be mutating a testbench.
    "probe_jtag": {
        "kind": "tcl",
        "sources": ["boards/arty-z7-20/vivado/probe.tcl"],
        "tb": "tb/cadr_probe_jtag_tb.tcl",
        "golden": None,
    },
    # The top level, and the only check that is lint alone: Verilator has no
    # `MMCME2_BASE`, so `cadr_arty` cannot be simulated. What lint holds is
    # the port list and the `witness` fold --- an output left off the
    # instantiation is a PINMISSING, one left out of the fold is an
    # UNUSEDSIGNAL. `extra` rather than `sources` for everything below the top
    # level, because `check_coverage` asks that every source a check builds has
    # a mutation aimed at it and only cadr_arty.sv does.
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
    # honours the first CCW of a list and not the rest --- which is what the
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
    "gp0_default": {
        "sources": ["rtl/plumbing/cadr_gp0_default.sv"],
        "top": "cadr_gp0_default",
        "tb": "tb/cadr_gp0_default_tb.cpp",
        "flags": [],
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
        "sources": ["rtl/plumbing/cadr_console.sv", "rtl/machine/cadr_console_bus.sv",
                    "rtl/machine/cadr_console_state.sv"],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv", "rtl/machine/cadr_microcycle.sv",
            "rtl/machine/cadr_spy_registers.sv", "tb/cadr_console_harness.sv",
        ],
        "top": "cadr_console_harness",
        "tb": "tb/cadr_console_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": "rtl.golden",
        "gprom": True,
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
            "rtl/machine/cadr_memory_path.sv",
        ],
        "top": "cadr_memory_path",
        "tb": "tb/cadr_unibus_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing",
                  "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": "iob.golden",
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

    # Names are how a survivor is reported and how CLAUDE.md's claim is read
    # against the list, so two of them may not collide.
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
    dirs = ["rtl", "tb", "boards"] + (["golden"] if with_golden else [])
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
    if check == "cables":
        return cables_check(args, work, build_fails)
    if check == "arty":
        return arty_check(args, work, build_fails)

    for src, dest in spec.get("files", []):
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
    if spec.get("gprom"):
        cmd += ["-GPROM_HEX=\"%s\""
                % os.path.join(args.goldens, "boot_prom.hex")]
    cmd += ["-Mdir", obj, "--top-module", spec["top"]]
    cmd += spec["sources"]
    # Everything the check builds that no mutation is aimed at: a wiring
    # harness, or a module with a check of its own.  `arty` has used the key
    # for that since it arrived; this is the same meaning in the one place
    # that builds rather than lints.
    cmd += spec.get("extra", [])
    cmd += [os.path.join(work, spec["tb"])]
    rc, out = run(cmd, work)
    if rc != 0:
        return BROKEN, first_problem(out)

    cmd = [os.path.join(obj, "V" + spec["top"])]
    if spec["golden"]:
        cmd.append(os.path.join(args.goldens, spec["golden"]))
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

    FIVE TIMES, BECAUSE THERE ARE FIVE BOARDS, exactly as `build/arty.pass`
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
         ["rtl/plumbing/xilinx7/cadr_probe.sv"]),
        # And the one with the processing system behind the memory port,
        # and the disk's pack side on the processing system's other two
        # ports.
        (["-GDDR=1"], ["tb/cadr_arty_stubs.sv", "tb/cadr_ps7_stub.sv"],
         ["boards/arty-z7-20/cadr_ps7.sv", "rtl/plumbing/cadr_axi_master.sv",
          "rtl/plumbing/cadr_axi_widen.sv", "rtl/plumbing/cadr_mem_count.sv",
          "rtl/plumbing/cadr_disk_pack.sv", "rtl/plumbing/cadr_console.sv"]),
        # And the two the witness builds, which are branches only they
        # reach: nothing else elaborates `cadr_prove.sv` at all, and neither
        # of them elaborates the machine's own drive of the port.
        # A proving board brings GP0 out without the pack side, and answers
        # every address on it with the default slave.
        (["-GPROVE=1"], ["tb/cadr_arty_stubs.sv", "tb/cadr_ps7_stub.sv"],
         ["boards/arty-z7-20/cadr_ps7.sv", "rtl/plumbing/cadr_axi_master.sv",
          "rtl/plumbing/cadr_axi_widen.sv", "rtl/plumbing/cadr_mem_count.sv",
          "rtl/plumbing/cadr_prove.sv", "rtl/plumbing/cadr_gp0_default.sv",
          "rtl/plumbing/cadr_console.sv"]),
        (["-GPROVE=2"], ["tb/cadr_arty_stubs.sv", "tb/cadr_ps7_stub.sv"],
         ["boards/arty-z7-20/cadr_ps7.sv", "rtl/plumbing/cadr_axi_master.sv",
          "rtl/plumbing/cadr_axi_widen.sv", "rtl/plumbing/cadr_mem_count.sv",
          "rtl/plumbing/cadr_prove.sv", "rtl/plumbing/cadr_gp0_default.sv",
          "rtl/plumbing/cadr_console.sv"]),
    ]
    ran = 0
    for generics, stubs, extra_sources in boards:
        files = stubs + extra_sources
        if not all(os.path.exists(os.path.join(work, f)) for f in files):
            continue
        cmd = base + generics + stubs + spec["extra"] + spec["sources"]
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
    times.  It is CLAUDE.md's stale-binary lesson exactly, in the mirror ---
    there it made mutations look like survivors, here it makes them look
    caught, and looking caught is worse because nothing is obviously wrong.
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
    name on the wire --- and CLAUDE.md says what cadr_cables.svh holds to is
    both netlists via `part::pinout`.  Only `current` enforces that: it
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


def check_coverage(mutations):
    """Sources a check builds that no mutation ever touches.

    The inverse of the `@file` validation, which catches a mutation naming a
    file its check does not build.  This catches the other direction --- a
    file the check builds that nothing is aimed at --- and that direction is
    the one that hides, because nothing about it is ever wrong: the run is
    green, the count is right, and a whole module is untested.
    """
    # The lint harness is generated, tied off and has no behaviour; what
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
    # than aiming a record is the second of the two ways CLAUDE.md says close
    # this warning, and it is the one that stands alone.
    # `checkpoint` is the same shape as `readout_face` and closed the same
    # way, and the reason is worth writing down rather than inherited: its
    # DUT is a C program under `boards/`, and its judge is muir's own reader.
    # It already carries mutations --- three of them, in `chk_rtl.c` behind
    # `CHK_MUTATE`, built by its own Makefile and run by its own rule, with
    # the catching line asserted and the leg that caught each one named.  A
    # record aimed at it here would be a fourth mutation run by a different
    # machinery against the same file, and this runner has no way to build a
    # C program three times over and put muir behind it.  So it is named
    # here, which is the one of CLAUDE.md's two ways that stands alone.
    known = set(CHECKS) | {"ddr_map", "readout_face", "checkpoint"}
    for found in sorted(set(re.findall(r"\$\(BUILD\)/([a-z_]+)\.pass", text))):
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
               "--tclsh", args.tclsh]
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
               "--tclsh", args.tclsh]
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
                   "--tclsh", args.tclsh]
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
    for name in os.listdir(args.goldens):
        if name.endswith(".golden"):
            shutil.copy(os.path.join(args.goldens, name),
                        os.path.join(here, name))
    cmd = [sys.executable, os.path.abspath(__file__),
           "--goldens", ".", "--work", "work",
           "--list", os.path.relpath(args.list, here),
           "--only", cheap.name, "--jobs", "2",
           "--verilator", args.verilator, "--cargo", args.cargo,
           "--tclsh", args.tclsh]
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
    ap.add_argument("--self-test", action="store_true",
                    help="check the runner's own guarantees, not the fabric")
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
        golden = CHECKS[check]["golden"]
        if golden and not os.path.exists(os.path.join(args.goldens, golden)):
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
    copy_tree(base, with_golden=generators, rev=args.rev)
    baseline_bad = False
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = dict((pool.submit(build_and_run, args, base, c), c)
                       for c in wanted)
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
        copy_tree(work, with_golden=CHECKS[m.check].get("kind") == "generator",
                  rev=args.rev)
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
                golden = CHECKS[other]["golden"]
                if golden and not os.path.exists(
                        os.path.join(args.goldens, golden)):
                    continue
                verdict, _ = build_and_run(args, work, other)
                if verdict == SURVIVED:
                    m.also.append(other)
        return m

    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        done = 0
        for m in pool.map(one, mutations):
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
                copy_tree(work, with_golden=CHECKS[m.check].get("kind")
                          == "generator", rev=args.since)
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
    the same shape as the divergences from muir that CLAUDE.md writes down.
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
