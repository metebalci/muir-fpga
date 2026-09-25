#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX'S DERIVED ACKNOWLEDGMENT, HELD BY THE ONE WITNESS THAT CAN SEE IT.
#
# At muir's pin `golden/src/trace.rs` derives QUUX's `ack` column instead of
# reading it (its `QuuxPort` says why and what it checks against muir).  One
# error in it muir's own behavior cannot show: a device's read acknowledged a
# tick early leaves every microcycle where it was, because QUUX's processor
# waits for READ IN PROGRESS 140 ns after the acknowledgment and both
# instants round up to the same master clock edge.  The fabric can: its
# -MEMACK is its own and `tb/cadr_machine_tb.cpp` compares it with the
# column on every cycle.
#
# So this builds the generator from the tree it is run in, takes a trace of
# QUUX's register page program with it --- device reads, main memory's reads
# and writes, timeouts --- builds the machine as QUUX from the same tree, and
# runs the testbench against the trace.  It exits 1 when the generator
# refuses or the machine and the trace disagree, which is what a derivation
# off by a tick makes them do, and 3 when either does not build, which is no
# verdict at all.  `make` never runs it: every QUUX machine check is this check on
# the tree's own trace.  `mutations/run.py` runs it on a tree whose
# generator is mutated (`quux_derivation`).
#
# Run from the root of a tree whose `golden/../../muir` is muir at the pin.

import glob
import os
import subprocess
import sys

K = 4
PROGRAM = "page"


def run(cmd, env=None, out=None):
    e = dict(os.environ)
    if env:
        e.update(env)
    sys.stdout.flush()
    if out:
        with open(out, "w") as f:
            return subprocess.call(cmd, env=e, stdout=f)
    return subprocess.call(cmd, env=e)


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    os.chdir(root)
    build = os.path.join(root, "build-derivation")
    os.makedirs(build, exist_ok=True)
    env = {"CARGO_TARGET_DIR": os.path.join(root, "cargo-target-derivation")}
    cargo = ["cargo", "run", "--quiet", "--release", "--manifest-path", "golden/Cargo.toml"]
    golden = os.path.join(build, "quux_%s.quux.k%d.golden" % (PROGRAM, K))
    prom = os.path.join(build, "quux_%s_prom.quux.hex" % PROGRAM)
    sync_prom = os.path.join(build, "sync_prom.hex")
    steps = [
        (cargo + ["--bin", "quux", "--", "--program", PROGRAM, "--machine", "quux",
                  "--sync-cycle-ticks", str(K), "--sync-ilong-ticks", "0"], golden),
        (cargo + ["--bin", "quux", "--", "--program", PROGRAM, "--machine", "quux", "--prom"], prom),
        (cargo + ["--bin", "sync_prom"], sync_prom),
    ]
    # Built first and apart, so that a generator that does not compile is a
    # broken run (exit 3) and never a disagreement.
    if run(["cargo", "build", "--quiet", "--release", "--manifest-path", "golden/Cargo.toml",
            "--bin", "quux", "--bin", "sync_prom"], env) != 0:
        print("quux_derivation: the generator did not build")
        return 3
    for cmd, out in steps:
        if run(cmd, env, out) != 0:
            print("quux_derivation: the generator refused: %s" % " ".join(cmd[6:]))
            return 1

    # The machine as QUUX, from this tree's sources: the grid's package and
    # the DDR map first, then every module of the machine and the three of
    # the plumbing it instantiates.
    pkg = ["rtl/machine/cadr_tick_pkg.sv", "rtl/plumbing/cadr_ddr_map.sv"]
    machine = sorted(f for f in glob.glob("rtl/machine/*.sv") if f not in pkg)
    plumbing = ["rtl/plumbing/cadr_xbus_ddr.sv", "rtl/plumbing/cadr_bus_audit.sv"]
    obj = os.path.join(build, "obj")
    cmd = ["verilator", "--cc", "--exe", "--build", "-Wall", "-Wno-DECLFILENAME",
           "+define+CADR_GAP_MONITOR", "-O2", "-CFLAGS", "-O2",
           "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20",
           "-Mdir", obj, '-GMACHINE="quux"', "-GSYNC_K=%d" % K, "-GSYNC_L=0",
           '-GPROM_HEX="%s"' % prom, '-GSYNC_PROM_HEX="%s"' % sync_prom,
           "--top-module", "cadr_machine"] + pkg + machine + plumbing + \
          [os.path.join(root, "tb/cadr_machine_tb.cpp")]
    if run(cmd, out=os.path.join(build, "verilator.log")) != 0:
        print("quux_derivation: the machine did not build: see %s" % os.path.join(build, "verilator.log"))
        return 3
    rc = run([os.path.join(obj, "Vcadr_machine"), golden])
    if rc != 0:
        print("quux_derivation: the machine and the trace disagree")
        return 1
    print("quux_derivation: the machine agrees with the trace the generator derived")
    return 0


if __name__ == "__main__":
    sys.exit(main())
