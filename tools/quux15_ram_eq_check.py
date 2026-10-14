#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Revision 15's RAMs on an Agilex 5, held to their behavioral versions.

    quux15_ram_eq_check.py mdmem|dmem|tdp|validmap --work <dir>

`rtl/plumbing/agilex5/` holds the Agilex 5 versions of some of
`rtl/machine/`'s RAMs (CLAUDE.md's vendor rule: a small module the machine
names, today's code as the behavioral version, an Altera one beside it,
shown equivalent by a check).  This is the check.  Each testbench is built
twice, once over each version, run under the same seeds, and the two
outputs must agree line for line:

  mdmem     `tb/quux15_mdmem_eq_tb.sv`: random writes and reads of the macro
            dispatch memory's five ports, 200,000 clocks under each of three
            seeds, the Agilex 5 version over `tb/quux15_altdpram_model.sv`,
            whose write window (the clock after the edge that takes a write)
            is poisoned.
  dmem      `tb/quux15_dmem_eq_tb.sv`: random writes and reads of dispatch
            memory's two ports, 200,000 clocks under each of three seeds,
            the Agilex 5 version's MLAB reads poisoned in their write window
            (`QUUX15_A5_MLAB_POISON`).
  tdp       `tb/quux15_tdp_eq_tb.sv`: every width and byte-enable form the
            core instantiates, 50,000 clocks under each of two seeds; and the
            Agilex 5 version given a write of part of a column on each port
            in turn, which its guard must refuse.
  validmap  `tb/quux15_validmap_eq_tb.sv`: random clears, writes and reads of
            the valid bits at each size and number of reads the core builds,
            200,000 clocks under each of three seeds, the Agilex 5 version's
            MLAB reads poisoned in their write window
            (`QUUX15_A5_MLAB_POISON`).

For mdmem, dmem and validmap the window must be reached: at least 1,000 reads in
it under each seed, or the forwarding is not being tested.

Exit 0 when they agree, 1 when they differ or a guard or the window is not
reached, and 2 when a build fails, which is never a verdict
(`mutations/run.py` reads 2 as BROKEN).  `VERILATOR` names the program.
"""
import argparse
import concurrent.futures
import os
import subprocess
import sys

VERILATOR = os.environ.get("VERILATOR", "verilator")
FLAGS = ["--binary", "--timing", "-Wall", "-O2", "-CFLAGS", "-O1", "--build", "-j", "2"]


def mdmem_window(lines):
    """Reads of the address the clock before wrote: `n we waddr wdata r0..r4 | ...`."""
    n, last = 0, None
    for line in lines:
        w = line.split()
        if last is not None:
            n += sum(1 for a in w[4:9] if a == last)
        last = w[2] if w[1] == "1" else None
    return n


def dmem_window(lines):
    """Reads of the address the clock before wrote: `n we waddr wdata ex ro | ...`."""
    n, last = 0, None
    for line in lines:
        w = line.split()
        if last is not None:
            n += sum(1 for a in w[4:6] if a == last)
        last = w[2] if w[1] == "1" else None
    return n


def validmap_window(lines):
    """Reads of the group the clock before wrote: `n rst clear we waddr wbit r0 r1 r2 | ...`."""
    n, last = 0, None
    for line in lines:
        w = line.split()
        if last is not None:
            n += sum(1 for a in w[6:9] if int(a, 16) >> 6 == last)
        last = int(w[4], 16) >> 6 if w[3] == "1" else None
    return n


RAMS = {
    "mdmem": {
        "tb": "tb/quux15_mdmem_eq_tb.sv",
        "top": "quux15_mdmem_eq_tb",
        "behavioral": ["rtl/machine/quux15_mdmem.sv"],
        "agilex5": ["rtl/plumbing/agilex5/quux15_mdmem.sv", "tb/quux15_altdpram_model.sv"],
        "agilex5_flags": [],
        "configs": [("", [])],
        "seeds": (1, 2, 3),
        "clocks": 200000,
        "window": mdmem_window,
    },
    "tdp": {
        "tb": "tb/quux15_tdp_eq_tb.sv",
        "top": "quux15_tdp_eq_tb",
        "behavioral": ["rtl/machine/quux15_tdp.sv"],
        "agilex5": ["rtl/plumbing/agilex5/quux15_tdp.sv"],
        "agilex5_flags": [],
        "configs": [("", [])],
        "seeds": (1, 2),
        "clocks": 50000,
        "window": None,
    },
    "dmem": {
        "tb": "tb/quux15_dmem_eq_tb.sv",
        "top": "quux15_dmem_eq_tb",
        "behavioral": ["rtl/machine/quux15_dmem.sv"],
        "agilex5": ["rtl/plumbing/agilex5/quux15_dmem.sv"],
        "agilex5_flags": ["+define+QUUX15_A5_MLAB_POISON"],
        "configs": [("", [])],
        "seeds": (1, 2, 3),
        "clocks": 200000,
        "window": dmem_window,
    },
    # The MMU's 4,096 entries and two reads; the cache's sets, three reads,
    # at the Kria's, the DE25-Nano's and the Arty's caches.
    "validmap": {
        "tb": "tb/quux15_validmap_eq_tb.sv",
        "top": "quux15_validmap_eq_tb",
        "behavioral": ["rtl/machine/quux15_validmap.sv"],
        "agilex5": ["rtl/plumbing/agilex5/quux15_validmap.sv"],
        "agilex5_flags": ["+define+QUUX15_A5_MLAB_POISON"],
        "configs": [("4096x2", ["-GENTRIES=4096", "-GREADS=2"]), ("4096x3", ["-GENTRIES=4096", "-GREADS=3"]),
                    ("1024x3", ["-GENTRIES=1024", "-GREADS=3"]), ("256x3", ["-GENTRIES=256", "-GREADS=3"])],
        "seeds": (1, 2, 3),
        "clocks": 200000,
        "window": validmap_window,
    },
}
GUARD = "a write of part of column"
WINDOW_FLOOR = 1000


def build(spec, impl, work, tag, extra=()):
    obj = os.path.join(work, impl + tag)
    flags = list(extra) + (spec["agilex5_flags"] if impl == "agilex5" else [])
    cmd = [VERILATOR] + FLAGS + flags + ["-Mdir", obj, "--top-module", spec["top"], spec["tb"]] + spec[impl]
    with open(obj + ".build.log", "w") as log:
        rc = subprocess.call(cmd, stdout=log, stderr=subprocess.STDOUT)
    return rc, os.path.join(obj, "V" + spec["top"]), obj + ".build.log"


def run(binary, seed, clocks, *more):
    p = subprocess.run([binary, "+seed=%d" % seed, "+clocks=%d" % clocks] + list(more),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    text = p.stdout.decode("utf-8", "replace")
    return p.returncode, [l for l in text.split("\n") if l[:1].isdigit()], text


def compare(name, spec, work):
    jobs = [(impl, tag, g) for tag, g in spec["configs"] for impl in ("behavioral", "agilex5")]
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        built = dict(zip([(i, t) for i, t, _ in jobs],
                         pool.map(lambda j: build(spec, j[0], work, j[1], j[2]), jobs)))
    for (impl, tag), (rc, _, log) in built.items():
        if rc != 0:
            print("quux15_ram_eq %s: the %s version%s does not build; see %s"
                  % (name, impl, " " + tag if tag else "", log))
            sys.exit(2)
    bad = False
    for tag, _ in spec["configs"]:
        at = " " + tag if tag else ""
        for seed in spec["seeds"]:
            out, ok = {}, True
            for impl in ("behavioral", "agilex5"):
                rc, lines, text = run(built[(impl, tag)][1], seed, spec["clocks"])
                if rc != 0 or len(lines) != spec["clocks"]:
                    print("quux15_ram_eq %s%s: the %s version stops at seed %d after %d of %d clocks: %s"
                          % (name, at, impl, seed, len(lines), spec["clocks"],
                             text.strip().split("\n")[-1][:200]))
                    ok = False
                out[impl] = lines
            b, a = out["behavioral"], out["agilex5"]
            first = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), None)
            if first is not None:
                print("quux15_ram_eq %s%s: seed %d: the versions DIFFER first at clock %d:" % (name, at, seed, first))
                print("  behavioral %s" % b[first][:200])
                print("  agilex5    %s" % a[first][:200])
                ok = False
            note = ""
            if ok and spec["window"]:
                n = spec["window"](b)
                note = ", %d reads in the write window" % n
                if n < WINDOW_FLOOR:
                    print("quux15_ram_eq %s%s: seed %d: only %d reads in the write window (at least %d wanted)"
                          % (name, at, seed, n, WINDOW_FLOOR))
                    ok = False
            if ok:
                print("quux15_ram_eq %s%s: ok      seed %d, %d clocks equal%s" % (name, at, seed, len(b), note))
            bad = bad or not ok
    return bad, built


def partial(spec, binary):
    """The Agilex 5 TDP given a write of part of a column on each port in
    turn: its guard stops it."""
    bad = False
    for port in ("a", "b"):
        rc, lines, text = run(binary, 1, spec["clocks"], "+partial=" + port)
        if rc == 0 or GUARD not in text:
            print("quux15_ram_eq tdp: a write of part of a column on port %s ran %d clocks and was not "
                  "refused by the agilex5 version's guard" % (port.upper(), len(lines)))
            bad = True
            continue
        print("quux15_ram_eq tdp: ok      a write of part of a column on port %s is refused at clock %d: %s"
              % (port.upper(), len(lines), next(l for l in text.split("\n") if GUARD in l).strip()[:160]))
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("ram", choices=sorted(RAMS))
    ap.add_argument("--work", required=True)
    args = ap.parse_args()
    os.makedirs(args.work, exist_ok=True)
    bad, built = compare(args.ram, RAMS[args.ram], args.work)
    if args.ram == "tdp":
        bad = partial(RAMS["tdp"], built[("agilex5", "")][1]) or bad
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
