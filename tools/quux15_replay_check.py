#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Revision 15's testbench, held to what it must catch, on its stand-in.

    quux15_replay_check.py <testbench> <trace>... [--as <reference> <planted>]...

`tb/quux15_core_tb.cpp` holds revision 15's core to a trace of
`golden/src/quux15.rs` clock for clock.  Built with `tb/quux15_replay.sv` as
the design, which plays a trace back, it must:

  pass each trace played back unchanged;
  fail a stub core, the stand-in showing zeros, at clock 0;
  fail one value changed in any column it compares, naming that clock and
  that column, the value changed at the last row the column is compared in,
  so that no column goes uncompared and the comparison runs to the end;
  pass one value changed where it compares nothing: an event's address or
  word in a clock without the event, a register in a clock without a commit,
  an output in a clock that committed no ALU or BYTE word, a nopped word's
  address, an empty stage's nop bit;
  fail a trace played against a reference it is not (`--as`): one taken
  with a fault planted in muir's pipeline that moves clocks and no result,
  or one taken at another period.

Every column must be caught in at least one trace.  The rules for what is
compared are the testbench's, written again here to choose where to plant;
if the two disagree a plant is not caught, or a control is, and this fails.
"""
import re
import subprocess
import sys

STAGES = {"cs", "rd", "ex", "wb", "commit"}
AT_COMMIT = {"pdlptr", "pdlidx", "spcptr", "q", "vma", "md", "lc", "ic", "opnd"}
OPERANDS = {"ea", "em", "ob"}
EVENT = {"gaddr": "grant", "mdword": "mdl", "raddr": "reg"}
FIRST = re.compile(r"^FAIL: .* the first at clock (\d+), (\w+)$", re.M)


def read(path):
    names, rows = None, []
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                w = line[1:].split()
                if w and w[0] == "clock":
                    names = w
                continue
            if line.strip():
                rows.append([int(x, 16) for x in line.split()])
    if names is None or len(rows) < 2:
        sys.exit("quux15_replay: %s has no header or fewer than two rows" % path)
    return names, rows


def compared(names, row, c):
    """Whether the testbench compares column `c` of `row`."""
    name = names[c]
    if name in AT_COMMIT:
        return bool(row[names.index("commit")] >> 15 & 1)
    if name in OPERANDS:
        return bool(row[names.index("commit")] >> 15 & 1) and row[names.index("opnd")] != 0
    if name in EVENT:
        return row[names.index(EVENT[name])] != 0
    return True


def plant(name, value):
    """A change the testbench compares, to a value of column `name`."""
    if name in STAGES:
        if not value >> 15 & 1:
            return 1 << 15
        if value >> 14 & 1:
            return 1 << 14
        return 1
    return 1


def run(tb, trace, args):
    p = subprocess.run([tb, trace] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out = p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")
    m = FIRST.search(out)
    return p.returncode, (int(m.group(1)), m.group(2)) if m else None, out


def fault(k, c, x):
    return ["+fault_clock=%d" % k, "+fault_col=%d" % c, "+fault_xor=%x" % x]


def check_trace(tb, path, caught, fails):
    names, rows = read(path)
    replay = ["+replay=" + path]

    rc, first, out = run(tb, path, replay)
    if rc != 0 or "ok:" not in out:
        fails.append("%s played back unchanged is not passed:\n%s" % (path, out.strip()))
    rc, first, out = run(tb, path, replay + ["+stub"])
    if rc != 1 or first is None or first[0] != 0:
        fails.append("%s: a stub core is not failed at clock 0 (exit %d, %s)" % (path, rc, first))

    planted = 0
    for c in range(1, len(names)):
        at = [k for k, row in enumerate(rows) if compared(names, row, c)]
        if not at:
            continue
        k = at[-1]
        rc, first, out = run(tb, path, replay + fault(k, c, plant(names[c], rows[k][c])))
        if rc == 1 and first == (k, names[c]):
            caught.add(names[c])
            planted += 1
        else:
            fails.append("%s: %s changed at clock %d is not named (exit %d, first %s)"
                         % (path, names[c], k, rc, first))

    # The controls: a change where the testbench compares nothing.
    controls = []
    for name, why in (("gaddr", "an address with no grant"), ("pdlptr", "a register with no commit"),
                      ("mdword", "a word with nothing landed"),
                      ("ob", "an output with no ALU or BYTE word committed")):
        c = names.index(name)
        at = [k for k, row in enumerate(rows) if not compared(names, row, c)]
        if at:
            controls.append((at[-1], c, 1, why))
    for name in ("cs", "rd", "ex", "wb"):
        c = names.index(name)
        nopped = [k for k, row in enumerate(rows) if row[c] >> 14 == 0b11]
        if nopped:
            controls.append((nopped[-1], c, 1, "a nopped word's address in " + name))
            break
    for name in ("wb", "ex", "rd"):
        c = names.index(name)
        empty = [k for k, row in enumerate(rows) if not row[c] >> 15 & 1]
        if empty:
            controls.append((empty[-1], c, 1 << 14, "an empty stage's nop bit in " + name))
            break
    for k, c, x, why in controls:
        rc, first, out = run(tb, path, replay + fault(k, c, x))
        if rc != 0:
            fails.append("%s: %s, changed at clock %d, is compared (exit %d, first %s)"
                         % (path, why, k, rc, first))
    print("quux15_replay: %s: %d clocks played back pass; a stub fails at clock 0; %d columns "
          "changed at their last compared clock each named; %d changes nothing compares pass"
          % (path, len(rows), planted, len(controls)))
    return names


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    tb, traces, pairs = args[0], [], []
    i = 1
    while i < len(args):
        if args[i] == "--as":
            pairs.append((args[i + 1], args[i + 2]))
            i += 3
        else:
            traces.append(args[i])
            i += 1
    caught, fails, names = set(), [], None
    for path in traces:
        names = check_trace(tb, path, caught, fails)
    missing = [n for n in (names or [])[1:] if n not in caught]
    if missing:
        fails.append("no trace has a change of %s caught" % ", ".join(missing))
    for reference, planted in pairs:
        rc, first, out = run(tb, reference, ["+replay=" + planted])
        if rc != 1 or first is None:
            fails.append("%s against %s is not failed (exit %d)" % (planted, reference, rc))
        else:
            print("quux15_replay: %s played against %s: failed, the first difference at clock "
                  "%d, %s" % (planted, reference, first[0], first[1]))
    for f in fails:
        print("quux15_replay: FAILED " + f)
    if fails:
        sys.exit("quux15_replay: %d failures" % len(fails))
    print("quux15_replay: ok, every column of %d traces caught; %d traces against another failed"
          % (len(traces), len(pairs)))


if __name__ == "__main__":
    main()
