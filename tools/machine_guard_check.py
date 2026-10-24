#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""QUUX's core's elaboration guards on the board's name.

    machine_guard_check.py --quux15 <source>...

`rtl/machine/quux15_core.sv` refuses at elaboration a board name over 20
characters, or with a byte outside `040`-`176` (contract HD).  Each refusal
is held here with its negative control: the core is linted with the value
just inside the rule, which must pass, and just outside it, which must stop
with the guard's own words.  A guard that refused everything, or nothing,
fails one of the pair.
"""
import os
import subprocess
import sys

VERILATOR = os.environ.get("VERILATOR", "verilator")

CASES = [
    # (what, parameters, None to pass or the words the refusal says)
    ("a 20-character name", ['-GBOARD_NAME="Full HD test, 20 ch."'], None),
    ("a 21-character name", ['-GBOARD_NAME="Full HD test, 21 ch.."'], "characters, over 20"),
    ("a name with a tab", ['-GBOARD_NAME="Kria\tKR260"'], "a byte outside 040-176"),
    ("a name with a byte over 176", ['-GBOARD_NAME="Kria KR260\x7f"'], "a byte outside 040-176"),
    ("a name of 040 and 176", ['-GBOARD_NAME=" ~"'], None),
    ("no name", [], None),
]


def main():
    if sys.argv[1:2] != ["--quux15"]:
        sys.exit("usage: machine_guard_check.py --quux15 <source>...")
    sources = sys.argv[2:]
    base = [VERILATOR, "--lint-only", "-Irtl/machine", "--top-module", "quux15_core"]
    cases = CASES
    bad = 0
    for what, params, refusal in cases:
        p = subprocess.run(base + params + sources, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = p.stdout.decode("utf-8", "replace")
        if refusal is None:
            ok = p.returncode == 0
            said = "elaborates" if ok else "is refused:\n" + out.strip()
        else:
            ok = p.returncode != 0 and refusal in out
            said = "is refused" if ok else ("elaborates" if p.returncode == 0 else
                                             "fails, and not with %r:\n%s" % (refusal, out.strip()))
        print("machine_guard: %s %s: %s" % ("ok     " if ok else "FAILED ", what, said))
        bad += not ok
    if bad:
        sys.exit("machine_guard: %d of %d cases are not as the rule says" % (bad, len(cases)))


if __name__ == "__main__":
    main()
