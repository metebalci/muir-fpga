#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""MIT's grid has more than one home, and the homes must agree.

`rtl/machine/cadr_tick_pkg.sv` is the grid for the fabric, `tb/cadr_tick.h`
for the testbenches, and every generator under `golden/src/` that turns a
nanosecond into a tick carries its own `TICK_NS`, being a separate binary with
no shared library.  A grid that differs between them does not fail to build.
It compares a correct design against the wrong instant, which is the failure
this project is least able to see, so this check says it out loud.

It fails when a home cannot be found as well as when two disagree: a pattern
that silently stopped matching would otherwise pass with nothing compared.

What it does NOT hold: the tick counts that timing constraints write out as
literals (`cadr_machine.xdc`'s fifteen, sixteen and thirty, their copies in the
probe constraints and in the flows' assertions).  Those are listed in
`docs/timing.md` and move when the grid does.

Usage: grid_check.py [ROOT]    (ROOT defaults to the current directory)
"""

import pathlib
import re
import sys


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def one(path, pattern, what):
    text = path.read_text()
    found = re.findall(pattern, text, re.MULTILINE)
    if len(found) != 1:
        fail(f"{path}: {what} found {len(found)} times, wanting exactly once")
    return int(found[0])


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")

    fabric = one(root / "rtl/machine/cadr_tick_pkg.sv",
                 r"^\s*localparam\s+int\s+unsigned\s+TICK_NS\s*=\s*(\d+)\s*;",
                 "the package's TICK_NS")
    bench = one(root / "tb/cadr_tick.h",
                r"^\s*constexpr\s+long\s+kGridNs\s*=\s*(\d+)\s*;",
                "the testbenches' kGridNs")
    if bench != fabric:
        fail(f"tb/cadr_tick.h says the grid is {bench} ns and "
             f"rtl/machine/cadr_tick_pkg.sv says {fabric} ns")

    generators = {}
    for rs in sorted((root / "golden/src").glob("*.rs")):
        for value in re.findall(
                r"^\s*(?:pub\s+)?const\s+TICK_NS\s*:\s*u64\s*=\s*(\d+)\s*;",
                rs.read_text(), re.MULTILINE):
            generators.setdefault(rs.name, []).append(int(value))
    if not generators:
        fail("no generator under golden/src/ names a TICK_NS, "
             "so there is nothing to hold them to")
    for name, values in generators.items():
        for value in values:
            if value != fabric:
                fail(f"golden/src/{name} says the grid is {value} ns and "
                     f"rtl/machine/cadr_tick_pkg.sv says {fabric} ns")

    count = sum(len(v) for v in generators.values())
    print(f"ok: the grid is {fabric} ns in the fabric, the testbenches and "
          f"{count} generator constants in {len(generators)} files")


if __name__ == "__main__":
    main()
