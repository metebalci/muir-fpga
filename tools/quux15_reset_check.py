#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Revision 15's reset asked for while the memory port is busy, as a check.

Runs `tb/quux15_reset_axi_tb.cpp` (built in `tb/quux15_reset_harness.sv`
behind each board's adapter) over a cut of the grid, the legs and the
controls, and holds each to what the rule (A15b.5's Drains and its
board-reset clarification) says:

  the grid       a request at every clock of a transaction: reads plain and
                 split, the program after the reset asking for the same line
                 or another, at a fast and a slow port; writes of one beat,
                 of two and split at 4 KiB, at fast and slow answers and
                 delayed readies; the read-back program across its 32
                 writes; requests of 1, 64 and 20,000 clocks; -RESET's sweep
                 of the TLB taken as done, so that nothing rests on its
                 4,095 clocks.  Every position must read 0 misbehaving:
                 quiet at the reset, every granted write landed, the cache
                 equal to memory at the release, nothing stray, late,
                 misdirected or withdrawn, no hang, memory and M as with no
                 reset.
  the adapters   a few sweeps each behind the Arty Z7-20's AXI3 shim (board
                 1) and the Kria KR260's narrow bursts on 128 bits (board 2),
                 and a sweep of requests made by the console face's RESET
                 key, whose answer must come after the reset.
  the hard reset at every clock of the read-back program's writes, one
                 sweep a board: the cache cleared with the port, so it equals
                 memory at the release and every word reads alike from the
                 cache and from memory; and every valid bit of both ways set
                 just before a hard reset and none left after it, at each
                 board's cache size (4K, 16K and 64K words).
  the legs       a bouncing button; a hard reset during a drain; a request
                 during an error halt and during the console's halt; a port
                 that stops answering, the request cut at the core's bound,
                 the core held until the hard reset, `rst_cut` set and kept,
                 the face's write answered at its bound.
  the controls   the port planted wrong, each of which must be counted.

  quux15_reset_check.py --tb0 B0 --tb1 B1 --tb2 B2 --ports TRACE --back TRACE
                        [--jobs N] [--out DIR] [--grid-only] [--first]

`--grid-only` runs the grid on board 0 alone and reports what it counts
without judging it: what a build of the core before the request shows.
`--first` stops at the first judgement that fails, each sweep at its first
position that misbehaves: a mutation run, where one failure is the catch.
Exits 0 when every judgement holds.
"""

import argparse
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

SPLIT = ["--amem", "f0000040=f0000330", "--amem", "f0000041=f0000331"]
OTHER = {"plain": ["--amem-after", "f0000040=f0000100", "--amem-after", "f0000041=f0000101"],
         "split": ["--amem-after", "f0000330=f0000100", "--amem-after", "f0000331=f0000101"]}
LENS = [1, 64, 20000]


def grid():
    """(name, board, trace key, run, args): the cut of the grid."""
    jobs = []
    k = 0
    for line in ("plain", "split"):
        for after in ("same", "other"):
            for lat, ad in ((2, 0), (300, 3)):
                a = (SPLIT if line == "split" else []) + (OTHER[line] if after == "other" else [])
                n = LENS[k % 3]
                k += 1
                jobs.append((f"read-{line}-{after}-r{lat}-ad{ad}-rl{n}", 0, "ports", "miss-then-hit",
                             ["--sweep", "read", "--target", "0", "--lat-r", str(lat), "--ar-delay", str(ad),
                              "--reset-len", str(n)] + a))
    for tg in ("0", "1", "split1"):
        for lb, aw, w in ((1, 0, 0), (100, 0, 3), (1, 3, 0)):
            a = ["--amem", "f0000401=f0000333"] if tg == "split1" else []
            n = LENS[k % 3]
            k += 1
            jobs.append((f"write-t{tg}-b{lb}-aw{aw}-w{w}-rl{n}", 0, "ports", "forty-writes-seed1",
                         ["--sweep", "write", "--target", "1" if tg == "split1" else tg, "--lat-b", str(lb),
                          "--aw-delay", str(aw), "--w-delay", str(w), "--reset-len", str(n)] + a))
    for lb, aw, w in ((1, 0, 0), (100, 0, 3), (300, 3, 0)):
        n = LENS[k % 3]
        k += 1
        jobs.append((f"readback-b{lb}-aw{aw}-w{w}-rl{n}", 0, "back", "resetback",
                     ["--resume", "--sweep", "write-span", "--target", "32", "--lat-b", str(lb), "--aw-delay",
                      str(aw), "--w-delay", str(w), "--reset-len", str(n), "--step", "3"]))
    return jobs


def adapters():
    jobs = []
    for b in (1, 2):
        jobs.append((f"b{b}-write-t1", b, "ports", "forty-writes-seed1",
                     ["--sweep", "write", "--target", "1", "--lat-b", "100", "--w-delay", "3", "--reset-len", "64"]))
        jobs.append((f"b{b}-write-split1", b, "ports", "forty-writes-seed1",
                     ["--sweep", "write", "--target", "1", "--lat-b", "1", "--reset-len", "1",
                      "--amem", "f0000401=f0000333"]))
        jobs.append((f"b{b}-read-split-other", b, "ports", "miss-then-hit",
                     ["--sweep", "read", "--target", "0", "--lat-r", "300", "--ar-delay", "3", "--reset-len",
                      "20000"] + SPLIT + OTHER["split"]))
        jobs.append((f"b{b}-readback", b, "back", "resetback",
                     ["--resume", "--sweep", "write-span", "--target", "32", "--lat-b", "100", "--reset-len", "64",
                      "--step", "5"]))
    jobs.append(("b1-face-write-t1", 1, "ports", "forty-writes-seed1",
                 ["--sweep", "write", "--target", "1", "--lat-b", "100", "--face-at", "0"]))
    jobs.append(("b2-face-read-split", 2, "ports", "miss-then-hit",
                 ["--sweep", "read", "--target", "0", "--lat-r", "300", "--face-at", "0"] + SPLIT))
    return jobs


def hard():
    jobs = []
    for b, lb in ((0, 300), (1, 100), (2, 1)):
        jobs.append((f"b{b}-hard-readback-b{lb}", b, "back", "resetback",
                     ["--resume", "--sweep", "write-span", "--target", "32", "--sweep-hard", "--lat-b", str(lb),
                      "--step", "3"]))
        jobs.append((f"b{b}-hard-clears-the-cache", b, "ports", "forty-writes-seed1",
                     ["--hard-at", "150", "--clear-check", "--lat-b", "100"]))
    return jobs


def legs():
    jobs = []
    for s in (1, 2, 3):
        jobs.append((f"bounce-{s}", 0, "ports", "forty-writes-seed1",
                     ["--reset-at", "100", "--bounce", str(s), "--lat-b", "100"]))
    jobs.append(("bounce-readback", 2, "back", "resetback", ["--resume", "--reset-at", "200", "--bounce", "4",
                                                             "--lat-b", "100"]))
    for at in (121, 125, 140):
        jobs.append((f"hard-in-drain-{at}", 0, "ports", "forty-writes-seed1",
                     ["--reset-at", "120", "--reset-len", "1", "--hard-at", str(at), "--lat-b", "100"]))
    jobs.append(("errhalt", 0, "ports", "forty-writes-seed1",
                 ["--errhalt-at", "150", "--reset-at", "160", "--lat-b", "100"]))
    jobs.append(("console-halt", 0, "ports", "forty-writes-seed1",
                 ["--halt-at", "150", "--reset-at", "155", "--lat-b", "100"]))
    jobs.append(("dead-btn", 1, "ports", "forty-writes-seed1",
                 ["--lat-b", "100", "--dead-at", "120", "--reset-at", "125", "--hard-at", "70000"]))
    jobs.append(("dead-face", 2, "ports", "forty-writes-seed1",
                 ["--lat-b", "100", "--dead-at", "120", "--face-at", "125", "--hard-at", "200000"]))
    return jobs


# The controls: each a single run that must misbehave, and the counts it
# must name.
CONTROLS = [
    ("control-extra-r", 0, "ports", "miss-then-hit", ["--reset-at", "2", "--fault", "extra-r"], ["stray_r_fill"]),
    ("control-extra-r-idle", 0, "ports", "miss-then-hit", ["--reset-at", "300", "--fault", "extra-r-idle"],
     ["stray_r_idle"]),
    ("control-extra-b", 0, "ports", "forty-writes-seed1", ["--reset-at", "300", "--fault", "extra-b"], ["late_b"]),
    ("control-ghost-aw", 0, "ports", "forty-writes-seed1", ["--reset-at", "300", "--fault", "ghost-aw"],
     ["misdirected_w"]),
    ("control-drop-b", 0, "ports", "forty-writes-seed1", ["--reset-at", "300", "--fault", "drop-b"],
     ["b_unanswered"]),
    ("control-drop-write", 0, "back", "resetback", ["--resume", "--reset-at", "300", "--fault", "drop-write"],
     ["lost"]),
]


FAILED = []


def run(tb, traces, out, job, first=False):
    name, board, trace, prog, args = job[:5]
    if first and FAILED:
        return name, -1, ""
    cmd = [tb[board], traces[trace], prog, "--sweep-after-reset", "--budget", "300000"] + args
    if first:
        cmd.append("--first")
    with open(os.path.join(out, name + ".log"), "w") as f:
        f.write("# " + " ".join(cmd) + "\n")
        f.flush()
        rc = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT).returncode
    with open(os.path.join(out, name + ".log")) as f:
        text = f.read()
    # A control is to misbehave; anything else that does, or exits but 0,
    # is a failure, which `--first` stops at.
    v = verdict(text)
    if len(job) == 5 and (v is None or v[1] or rc != 0):
        FAILED.append(name)
    elif len(job) == 6 and (v is None or v[1] != 1):
        FAILED.append(name)
    return name, rc, text


def verdict(text):
    """(positions, misbehaving, the tally) from a run's output."""
    m = re.search(r"^SUMMARY .*: (\d+) positions, (\d+) misbehave;(.*)$", text, re.M)
    if m:
        return int(m.group(1)), int(m.group(2)), m.group(3).strip()
    m = re.search(r"^single pos \S+: (ok|MISBEHAVES) .*?(\S*)$", text, re.M)
    if m:
        return 1, int(m.group(1) == "MISBEHAVES"), m.group(2) if m.group(1) == "MISBEHAVES" else ""
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tb0", required=True)
    ap.add_argument("--tb1")
    ap.add_argument("--tb2")
    ap.add_argument("--ports", required=True)
    ap.add_argument("--back", required=True)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--out", default="build/quux15_reset_axi")
    ap.add_argument("--grid-only", action="store_true")
    ap.add_argument("--first", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    tb = {0: a.tb0, 1: a.tb1, 2: a.tb2}
    traces = {"ports": a.ports, "back": a.back}
    jobs = grid() if a.grid_only else grid() + adapters() + hard() + legs() + CONTROLS
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        results = list(ex.map(lambda j: run(tb, traces, a.out, j, a.first), jobs))
    want = {c[0]: c[5] for c in CONTROLS}
    bad = 0
    total_pos = total_bad = 0
    for (name, rc, text) in results:
        if rc == -1:
            continue   # not run: `--first` had a failure already
        v = verdict(text)
        if v is None:
            print(f"FAIL {name}: no result (exit {rc}): {text.strip().splitlines()[-1] if text.strip() else ''}")
            bad += 1
            continue
        pos, mis, tally = v
        total_pos += pos
        if name in want:
            ok = mis == 1 and all(re.search(rf"\b{w}=", tally) for w in want[name])
            print(f"{'ok  ' if ok else 'FAIL'} {name}: counted {tally or 'nothing'}, wanting {', '.join(want[name])}")
            bad += not ok
            continue
        total_bad += mis
        if a.grid_only:
            print(f"     {name}: {pos} positions, {mis} misbehave {tally}")
            continue
        ok = mis == 0 and rc == 0
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {pos} positions, {mis} misbehave {tally}")
        bad += not ok
    print(f"quux15_reset_axi: {len(results)} runs, {total_pos} positions, {total_bad} misbehave"
          + ("" if a.grid_only else f"; {bad} failing") )
    return 0 if a.grid_only or bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
