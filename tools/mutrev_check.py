#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Whether `make mutants` passes `MUTREV` to the runner as it says it does.

    python3 tools/mutrev_check.py .

`MUTREV` is the commit whose sources the mutation runner copies:

- unset, `--rev HEAD`, the committed sources;
- given, `--rev <it>`;
- empty (`make mutants MUTREV=`), no `--rev` at all, so the runner mutates
  the working tree and prints its own warning when the tree is not clean.

An empty value once reached the runner as a bare `--rev` followed by the next
option, which argparse refused.  This asks make itself, with `make -n`, for
the command each form runs, so it builds nothing and takes well under a
second.
"""

import os
import re
import shlex
import subprocess
import sys

SHA = "0123456789abcdef0123456789abcdef01234567"

# (what it is called, extra make arguments, the --rev value expected or None)
CASES = [
    ("MUTREV unset", [], "HEAD"),
    ("MUTREV empty", ["MUTREV="], None),
    ("MUTREV=<sha>", ["MUTREV=" + SHA], SHA),
]


def runner_command(directory, extra):
    """The words of the mutation runner's command line `make -n mutants` prints."""
    env = dict(os.environ)
    # Run as a top-level make whatever calls this: a parent make's flags
    # (`-n`, `-k`, jobs) and an inherited MUTREV would change the answer.
    for var in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MUTREV"):
        env.pop(var, None)
    out = subprocess.run(
        ["make", "-n", "--no-print-directory", "-C", directory, "mutants",
         *extra],
        capture_output=True, text=True, env=env)
    if out.returncode != 0:
        raise RuntimeError("make -n mutants %s failed:\n%s"
                           % (" ".join(extra), out.stderr.strip()))
    text = out.stdout.replace("\\\n", " ")
    lines = [l for l in text.splitlines()
             if re.search(r"\bmutations/run\.py\b", l)]
    if len(lines) != 1:
        raise RuntimeError("expected one mutations/run.py line, found %d"
                           % len(lines))
    return shlex.split(lines[0])


def main():
    directory = sys.argv[1] if len(sys.argv) > 1 else "."
    bad = 0
    for name, extra, want in CASES:
        try:
            words = runner_command(directory, extra)
        except RuntimeError as e:
            print("mutrev: %-14s FAILED: %s" % (name, e))
            bad += 1
            continue
        revs = [i for i, w in enumerate(words) if w == "--rev"]
        if want is None:
            ok = not revs
            got = "no --rev" if ok else "--rev %s" % (
                words[revs[0] + 1] if revs[0] + 1 < len(words) else "")
            expect = "no --rev"
        else:
            got = ("--rev %s" % words[revs[0] + 1]
                   if len(revs) == 1 and revs[0] + 1 < len(words)
                   else "%d --rev" % len(revs))
            expect = "--rev %s" % want
            ok = got == expect
        print("mutrev: %-14s %-8s expected %s, got %s"
              % (name, "ok" if ok else "FAILED", expect, got))
        bad += not ok
    if bad:
        print("mutrev: %d of %d forms wrong" % (bad, len(CASES)))
        return 1
    print("mutrev: make mutants passes MUTREV as documented")
    return 0


if __name__ == "__main__":
    sys.exit(main())
