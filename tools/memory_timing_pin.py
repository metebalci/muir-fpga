#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Each board's QUUX checkpoint declares muir's own memory timing for that
board, and the figures are muir's at the pinned commit.

WHY THIS EXISTS.  muir refuses a QUUX checkpoint whose memory port's timing
is not the resuming machine's, and a board's resume line names the timing
only by the name of muir's preset (`--memory-timing kria`, `arty` or
`de25`).  So the board's file must carry exactly the figures muir gives that
name.  They are written twice: in muir's `src/pipeline/port.rs`
(`PortTiming::KRIA`, `ARTY` and `DE25`, and `PortTiming::preset`, which maps
a name to one), and in `cadr-checkpoint`'s `chk_rtl.c` (`chk_memory_timings`),
which the board's writer declares; and each board names its preset in
`cadr_board.h` (`CADR_BOARD_MEMORY_TIMING`).  Nothing that runs on the build
host resumes a board's own file, so a figure left behind when muir's moved
was found only by muir refusing the file.

WHAT IT HOLDS.  muir's side is read out of `port.rs` AT THE COMMIT
`muir.commit` NAMES (`git show`), not out of whatever muir is checked out.
The tree's side is compiled, not read as text: a small program built once per
board with that board's define, as the board's packages build theirs, prints
the board's name, the preset it names and the table `chk_memory_timing`
answers from.  Then:

  * the table has exactly muir's presets, each with muir's three figures;
  * each board names its own: the Kria KR260 `kria`, the Arty Z7-20 (the
    Zynq-7000 map) `arty`, the DE25-Nano `de25`.  That pairing is this
    file's own, and it is muir's: its presets are named for the boards;
  * and the figures `chk_memory_timing` gives each board's name are muir's.

Exit 0 when all of it holds, 1 when anything differs, and 2 when the check
cannot run: no muir, no pin, or a program that does not build.

    tools/memory_timing_pin.py [TREE] [--repo DIR] [--muir DIR] [--work DIR]

TREE is the tree whose sources are checked (default `.`).  `--repo` is where
`muir.commit` is (default TREE), `--muir` the muir-sim repository (default
`<repo>/../muir-sim`, as `golden/Cargo.toml` finds it), and `--work` the
scratch directory for the builds (default `<TREE>/build/memory_timing_pin`).
"""

import argparse
import os
import re
import subprocess
import sys

PKG = "boards/arty-z7-20/linux/buildroot/package"
CHK = PKG + "/cadr-checkpoint/src"
READOUT = PKG + "/cadr-readout/src"
COMMON = PKG + "/cadr-common/src"

# The board's define, as `cadr-common/src/Makefile`'s BOARD_DEFINE_* give it,
# and the preset of muir's each board's file is to declare.
BOARDS = [
    ("kria-kr260", "CADR_BOARD_KR260", "kria"),
    ("zynq-7000", "CADR_BOARD_ZYNQ7000", "arty"),
    ("de25-nano", "CADR_BOARD_DE25_NANO", "de25"),
]

PRINTER = r"""
#include <stdio.h>
#include "chk_rtl.h"
#include "cadr/cadr_board.h"
int main(void)
{
	printf("board %s %s\n", CADR_BOARD_NAME, CADR_BOARD_MEMORY_TIMING);
	for (const struct chk_memory_timing *t = chk_memory_timings; t->name; ++t)
		printf("preset %s %llu %llu %llu\n", t->name, (unsigned long long)t->read_ns,
		       (unsigned long long)t->write_ns, (unsigned long long)t->occupancy_ns);
	const struct chk_memory_timing *b = chk_memory_timing(CADR_BOARD_MEMORY_TIMING);
	if (b)
		printf("declared %s %llu %llu %llu\n", b->name, (unsigned long long)b->read_ns,
		       (unsigned long long)b->write_ns, (unsigned long long)b->occupancy_ns);
	else
		printf("declared none\n");
	return 0;
}
"""


def cannot(msg):
    print("memory-timing-pin: CANNOT RUN: " + msg)
    sys.exit(2)


def muir_presets(muir, pin):
    """{name: (read, write, occupancy)} out of port.rs at `pin`."""
    path = "src/pipeline/port.rs"
    r = subprocess.run(["git", "-C", muir, "show", "%s:%s" % (pin, path)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        cannot("muir's %s at %s: %s" % (path, pin, r.stderr.strip()))
    text = r.stdout
    consts = {}
    for name, rd, wr, oc in re.findall(
            r"pub const ([A-Z0-9_]+): PortTiming = PortTiming \{\s*read_ns:\s*(\d+),\s*"
            r"write_ns:\s*(\d+),\s*occupancy_ns:\s*(\d+)\s*\}", text):
        consts[name] = (int(rd), int(wr), int(oc))
    m = re.search(r"pub fn preset\(name: &str\) -> Option<PortTiming> \{(.*?)\n    \}", text, re.S)
    if not m:
        return None, "muir's %s at %s has no `PortTiming::preset` this check can read" % (path, pin[:12])
    presets = {}
    for name, const in re.findall(r'"([a-z0-9]+)"\s*=>\s*Some\(PortTiming::([A-Z0-9_]+)\)', m.group(1)):
        if const not in consts:
            return None, "muir's preset %s names PortTiming::%s, which %s does not define as figures" % (
                name, const, path)
        presets[name] = consts[const]
    if not presets:
        return None, "muir's `PortTiming::preset` at %s names no preset" % pin[:12]
    return presets, None


def board_reading(tree, work, board, define):
    """What the program built for `board` prints, as (named, table, declared)."""
    os.makedirs(work, exist_ok=True)
    src = os.path.join(work, "printer.c")
    with open(src, "w") as f:
        f.write(PRINTER)
    exe = os.path.join(work, "printer-" + board)
    cmd = ["cc", "-O0", "-Wall", "-Wextra", "-Werror", "-std=gnu11", "-D" + define,
           "-I" + os.path.join(tree, CHK), "-I" + os.path.join(tree, READOUT),
           "-I" + os.path.join(tree, COMMON), "-o", exe, src,
           os.path.join(tree, CHK, "chk_rtl.c"), os.path.join(tree, CHK, "chk.c"),
           os.path.join(tree, READOUT, "readout.c")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        cannot("the program for %s does not build:\n%s" % (board, (r.stderr or r.stdout).strip()))
    r = subprocess.run([exe], capture_output=True, text=True)
    if r.returncode != 0:
        cannot("the program for %s did not run: %s" % (board, r.stderr.strip()))
    named, table, declared = None, {}, None
    for line in r.stdout.splitlines():
        w = line.split()
        if w[0] == "board":
            named = (w[1], w[2])
        elif w[0] == "preset":
            table[w[1]] = tuple(int(x) for x in w[2:5])
        elif w[0] == "declared":
            declared = None if w[1] == "none" else (w[1], tuple(int(x) for x in w[2:5]))
    return named, table, declared


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tree", nargs="?", default=".")
    ap.add_argument("--repo")
    ap.add_argument("--muir")
    ap.add_argument("--work")
    a = ap.parse_args()
    tree = os.path.abspath(a.tree)
    repo = os.path.abspath(a.repo or tree)
    muir = os.path.abspath(a.muir or os.path.join(repo, "..", "muir-sim"))
    work = os.path.abspath(a.work or os.path.join(tree, "build", "memory_timing_pin"))
    try:
        pin = "".join(l.strip() for l in open(os.path.join(repo, "muir.commit"))
                      if not l.startswith("#"))
    except OSError as e:
        cannot("no pin: %s" % e)
    if not re.fullmatch(r"[0-9a-f]{40}", pin):
        cannot("muir.commit names %r, not a commit" % pin)

    wrong = []
    muir_table, why = muir_presets(muir, pin)
    if why:
        wrong.append(why)
    tables = {}
    for board, define, want in BOARDS:
        named, table, declared = board_reading(tree, os.path.join(work, board), board, define)
        tables[board] = table
        if not named or named[0] != board:
            wrong.append("built with %s, the program says it is %s" % (define, named and named[0]))
            continue
        if named[1] != want:
            wrong.append("%s names muir's preset %s, and its own is %s" % (board, named[1], want))
        if declared is None:
            wrong.append("%s names %s, which chk_memory_timing has no figures for" % (board, named[1]))
        elif muir_table and declared[0] in muir_table and declared[1] != muir_table[declared[0]]:
            wrong.append("%s declares %s as %s, and muir's %s at %s is %s" % (
                board, declared[0], ",".join(map(str, declared[1])), declared[0], pin[:12],
                ",".join(map(str, muir_table[declared[0]]))))
    table = tables[BOARDS[0][0]]
    if muir_table:
        for name in sorted(set(table) | set(muir_table)):
            if name not in table:
                wrong.append("muir has the preset %s, and chk_rtl.c's table has not" % name)
            elif name not in muir_table:
                wrong.append("chk_rtl.c's table has %s, which muir has no preset of" % name)
            elif table[name] != muir_table[name]:
                wrong.append("chk_rtl.c's %s is %s, and muir's at %s is %s" % (
                    name, ",".join(map(str, table[name])), pin[:12],
                    ",".join(map(str, muir_table[name]))))

    if wrong:
        print("memory-timing-pin: FAIL: %d difference(s) from muir at %s:" % (len(wrong), pin[:12]))
        for w in wrong:
            print("    " + w)
        return 1
    for board, _, want in BOARDS:
        print("memory-timing-pin: %s declares muir's %s, %s ns" % (
            board, want, ",".join(map(str, muir_table[want]))))
    print("memory-timing-pin: chk_rtl.c's %d presets are muir's at %s" % (len(muir_table), pin[:12]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
