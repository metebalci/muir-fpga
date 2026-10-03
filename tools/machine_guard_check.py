#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The machine's elaboration guards on the board's video size and name.

    machine_guard_check.py <source>...

`rtl/machine/cadr_machine.sv` refuses at elaboration a board name over 20
characters, with a byte outside `040`-`176`, and a video controller muir's
`check_video_size` would refuse (contract HD).  Each refusal is held here
with its negative control: QUUX at revision 13 is linted with the value just
inside the rule, which must pass, and just outside it, which must stop with
the guard's own words.  A guard that refused everything, or nothing, fails one
of the pair.
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
    ("1920 by 1080", ["-GVIDEO_WIDTH=1920", "-GVIDEO_HEIGHT=1080"], None),
    ("1952 by 1080", ["-GVIDEO_WIDTH=1952", "-GVIDEO_HEIGHT=1080"], "cannot be"),
    ("1920 by 1081", ["-GVIDEO_WIDTH=1920", "-GVIDEO_HEIGHT=1081"], "cannot be"),
    ("1900 by 1000, a line not whole words", ["-GVIDEO_WIDTH=1900", "-GVIDEO_HEIGHT=1000"], "cannot be"),
    ("1024 by 768", ["-GVIDEO_WIDTH=1024", "-GVIDEO_HEIGHT=768"], None),
]


def main():
    sources = sys.argv[1:]
    base = [VERILATOR, "--lint-only", "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7",
            "-Iboards/arty-z7-20", '-GMACHINE="quux"', "-GWORD_BITS=40", "--top-module", "cadr_machine"]
    bad = 0
    for what, params, refusal in CASES:
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
        sys.exit("machine_guard: %d of %d cases are not as the rule says" % (bad, len(CASES)))


if __name__ == "__main__":
    main()
