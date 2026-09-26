# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The cheap guard in front of the expensive one: does every record still
name a block of source that exists, exactly once?

**A RECORD WHOSE `@old` MATCHES NOTHING DOES NOT WEAKEN `make mutants`, IT
KILLS IT.**  `parse()` refuses the whole list, so one rotted anchor takes
every other record with it and the run ends with no summary line at all.
That happened at `6b9dcbf` and eleven commits were gated and pushed before
anybody noticed, because `make check` does not run the mutation suite.
The cheap guard that would have caught it is exactly this: a few seconds of
Python over `mutations/run.py`'s own `parse()`, run at the commit that broke
it.

It uses the runner's `parse()` and not its own reader, so the two cannot
drift apart about what a record is.  What it adds is the one thing `parse()`
deliberately does not do: open the file each record names and count.  The
runner itself only finds out at the moment it applies a mutation, which is
minutes in and, for `--since`, against a revision where the answer may
legitimately differ.

    make mutants-anchors

It is seconds, it needs no traces and no Verilator, and it is worth running
after any change to a file a record names --- which is `docs/mutations.md`'s
rule that a change touching a file re-runs every record aimed at that file,
made cheap enough to do every time.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import run  # noqa: E402  --- the runner's own parse, deliberately


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else run.LIST
    mutations = run.parse(path)

    wrong = 0
    missing = set()
    for m in mutations:
        full = os.path.join(run.REPO, m.path)
        try:
            with open(full) as f:
                src = f.read()
        except OSError:
            if m.path not in missing:
                sys.stderr.write("anchors: %s names %s, which is not there\n"
                                 % (m.name, m.path))
                missing.add(m.path)
            wrong += 1
            continue
        # `parse()` keeps `@old` as whole lines with its trailing newline, so
        # the count is of the block as the runner will look for it --- and a
        # block that is a prefix of a longer line cannot match, which is the
        # point of keeping the newline rather than stripping it.
        n = src.count(m.old)
        if n != 1:
            sys.stderr.write(
                "anchors: %s:%d: `%s` matches %s %d times, want exactly once\n"
                % (path, m.line, m.name, m.path, n))
            wrong += 1

    if wrong:
        sys.stderr.write(
            "anchors: %d of %d records name source that is not there, or is\n"
            "         there twice.  `make mutants` would stop at parse for\n"
            "         EVERY record, with no summary line.\n"
            % (wrong, len(mutations)))
        return 1

    files = sorted(set(m.path for m in mutations))
    print("ok: all %d records name a block that appears exactly once, over %d files"
          % (len(mutations), len(files)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
