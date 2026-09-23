#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Whether each program's host check works in a directory of this tree's own.

    python3 tools/work_dir_check.py .

A package's host check builds its test binaries into a work directory and
rebuilds them only when they are older than its sources.  A work directory
shared by two trees therefore lets the newer tree's binaries run in place of
the older tree's sources, which reports on code the tree under test does not
have: measured, a gate over one worktree failed on another worktree's
checkpoint format.  So this asks make, rather than reading the text:

- every package whose Makefile has a `WORK` default expands it to a path
  that carries its own directory's path hashed, as `cadr-console`'s does,
  so two copies of the tree never share one;
- the top-level Makefile's `CHECKPOINT_WORK` is under this tree's `build/`;
- every call the top-level Makefile makes into `cadr-checkpoint` passes that
  directory as `WORK`, so the package's own default is never the one used,
  and `make -n` shows it passed on the commands the check actually runs.
"""

import hashlib
import os
import re
import subprocess
import sys

PACKAGES = "boards/arty-z7-20/linux/buildroot/package"


def expand(directory, variable, *extra):
    """The value make gives `variable` in `directory`, fully expanded."""
    out = subprocess.run(
        ["make", "-s", "--no-print-directory", "-C", directory, *extra,
         "--eval", f"print-work-dir-check: ; @echo '$({variable})'",
         "print-work-dir-check"],
        capture_output=True, text=True, check=True)
    return out.stdout.strip().splitlines()[-1]


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    fails = []
    seen = {}
    for pkg in sorted(os.listdir(os.path.join(root, PACKAGES))):
        src = os.path.join(root, PACKAGES, pkg, "src")
        mk = os.path.join(src, "Makefile")
        if not os.path.isfile(mk):
            continue
        if not re.search(r"^WORK\s*\??=", open(mk).read(), re.M):
            continue
        work = expand(src, "WORK")
        want = hashlib.sha256(src.encode()).hexdigest()[:12]
        if want not in work:
            fails.append(f"{pkg}: WORK is {work}, which does not carry its "
                         f"own directory's hash {want}, so another tree shares it")
        if work in seen:
            fails.append(f"{pkg}: WORK {work} is {seen[work]}'s as well")
        seen[work] = pkg

    build = os.path.join(root, "build")
    cw = expand(root, "CHECKPOINT_WORK")
    if os.path.commonpath([cw, build]) != build:
        fails.append(f"CHECKPOINT_WORK is {cw}, outside this tree's {build}")

    # The commands the checkpoint check runs, as make would run them.
    dry = subprocess.run(
        ["make", "-n", "--no-print-directory", "-C", root, "-W",
         os.path.join(PACKAGES, "cadr-checkpoint/src/chk.c"),
         "build/checkpoint.pass"],
        capture_output=True, text=True)
    calls = [l for l in dry.stdout.splitlines()
             if re.search(r"make\S*\s.*-C\s+\S*cadr-checkpoint/src", l)]
    if len(calls) < 4:
        fails.append(f"make -n shows {len(calls)} calls into cadr-checkpoint, "
                     f"wanting the four the check makes")
    for l in calls:
        if f"WORK={cw}" not in l:
            fails.append(f"a call into cadr-checkpoint does not pass WORK={cw}: {l.strip()}")

    if fails:
        for f in fails:
            print("FAIL:", f)
        return 1
    print(f"ok: {len(seen)} packages work in a directory of their own tree, "
          f"and the checkpoint check's {len(calls)} calls pass {cw}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
