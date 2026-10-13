#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Whether revision 15's Kria KR260 top level hands its modules the board's
figures, read at the instances.

    python3 tools/quux15_kr260_param_check.py <the top's sources>

`boards/kria-kr260/quux15_kr260.sv` decides two kinds of figure that no
check of a module can see, because each module's own check builds it with
the figure directly:

**THE VIDEO CONTROLLER'S SIZE** (contract HD): the Kria's 1920 by 1080, at
the core (`VIDEO_W`, `VIDEO_H` and its frame buffer's `FB_WORDS`, which feature
words 11 and 12 and the window take), at the console face (word 39), and at
the display output (`PIC_W`, `PIC_H`, `WORDS_PER_LINE`), whose raster is
`boards/kria-kr260/display_raster.mk`'s, the figures
`build/display_out_kr260.quux15.pass` holds it at.

**EVERY TIME IN CLOCKS IS THE PERIOD'S** (the MP5a review's R9): each module
states a duration in clocks of the 10 ns tick, and the top turns it into
clocks of `PERIOD_NS`.  For each period asked, this reads back the display's
`SECOND_T` (a second, to the nearest clock), the microcycle lamp's `HOLD_T`
(2^22 ticks of 10 ns, rounded up) and the input's `MOUSE_STEP_T` (muir's
16,000 ns, rounded up), against figures computed here from the period, apart
from the top's arithmetic.  A top that left any of them at its tick count
passes at 10 ns and is caught at every other period.

**THE VALUE IS READ AT THE INSTANCE, NOT INFERRED FROM THE TEXT**: Verilator
elaborates the top at each period, after a lint with `-Wall`, and writes its
tree as JSON, as `tools/machine_param_check.py` does for the other tops.

Exit status 0 when every figure agrees, 1 otherwise, each printed either way.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from machine_param_check import params_at_cell  # noqa: E402

VERILATOR = os.environ.get("VERILATOR", "verilator")
TOP = "quux15_kr260"
# The periods the board's fits are asked for, and 10 ns, the tick, where a
# figure left at its tick count agrees by accident.
PERIODS = (10, 13, 18, 19)
# Contract HD: the Kria's video controller.  Written here apart from the top.
VIDEO = (1920, 1080)

failures = []


def say(ok, what):
    print("quux15_kr260_param: %s %s" % ("ok     " if ok else "FAILED ", what))
    if not ok:
        failures.append(what)


def run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def raster():
    with open("boards/kria-kr260/display_raster.mk") as f:
        text = f.read()
    m = re.search(r"^DISPLAY_KR260_G\s*:=((?:.*\\\n)*.*)$", text, re.M)
    want = {}
    if m:
        for k, v in re.findall(r"-G(\w+)=(\d+)", m.group(1)):
            want[k] = int(v)
    return want


def check(want, got, why, what):
    if got is None:
        say(False, "%s --- %s" % (what, why or "no such cell"))
    elif got != want:
        say(False, "%s --- it elaborates %s, want %s" % (
            what, ", ".join("%s=%d" % kv for kv in sorted(got.items())),
            ", ".join("%s=%d" % kv for kv in sorted(want.items()))))
    else:
        say(True, "%s: %s" % (what, ", ".join("%s=%d" % kv for kv in sorted(got.items()))))


def at_period(period, sources, scratch):
    base = [VERILATOR, "-DCADR_DDR_MAP_KR260", "-Irtl/machine", "-Irtl/plumbing",
            "-Irtl/plumbing/xilinx7", "-Iboards/kria-kr260", "--top-module", TOP,
            "-GPERIOD_NS=%d" % period]
    rc, out = run(base[:1] + ["--lint-only", "-Wall"] + base[1:] + sources)
    if rc != 0:
        say(False, "PERIOD_NS=%d: the lint failed:\n%s" % (period, out.strip()))
        return
    mdir = tempfile.mkdtemp(dir=scratch)
    rc, out = run(base[:1] + ["--json-only", "-Mdir", mdir] + base[1:] + sources)
    if rc != 0:
        say(False, "PERIOD_NS=%d: the JSON dump failed:\n%s" % (period, out.strip()))
        return
    with open(os.path.join(mdir, "V%s.tree.json" % TOP)) as f:
        tree = json.load(f)
    shutil.rmtree(mdir, True)
    w, h = VIDEO
    at = "PERIOD_NS=%d" % period

    # The times, from the period here.
    second = (10 ** 9 + period // 2) // period
    hold = -(-41_943_040 // period)
    step = -(-16_000 // period)
    want = raster()
    want.update({"PIC_W": w, "PIC_H": h, "WORDS_PER_LINE": w // 32, "SPREAD": 0,
                 "SECOND_T": second})
    got, why = params_at_cell(tree, TOP, "u_display", list(want))
    check(want, got, why, "%s, u_display: the raster, the picture and a second" % at)
    want = {"HOLD_T": hold}
    got, why = params_at_cell(tree, TOP, "u_lamp_microcycle", list(want))
    check(want, got, why, "%s, u_lamp_microcycle: the hold" % at)
    want = {"MOUSE_STEP_T": step}
    got, why = params_at_cell(tree, TOP, "u_input", list(want))
    check(want, got, why, "%s, u_input: the mouse's step" % at)

    # The video controller's size, the same at every period.
    want = {"VIDEO_W": w, "VIDEO_H": h, "FB_WORDS": w // 32 * h}
    got, why = params_at_cell(tree, TOP, "u_core", list(want))
    check(want, got, why, "%s, u_core: the video controller" % at)
    want = {"VIDEO_W": w, "VIDEO_H": h}
    got, why = params_at_cell(tree, TOP, "u_face", list(want))
    check(want, got, why, "%s, u_face: word 39" % at)


def main():
    sources = sys.argv[1:]
    if not sources:
        print(__doc__)
        return 2
    if sorted(raster()) != sorted(["H_ACTIVE", "H_FRONT", "H_SYNC", "H_BACK",
                                   "V_ACTIVE", "V_FRONT", "V_SYNC", "V_BACK"]):
        say(False, "display_raster.mk names %s" % sorted(raster()))
    scratch = tempfile.mkdtemp(prefix="quux15_kr260_param.", dir="build")
    try:
        for p in PERIODS:
            at_period(p, sources, scratch)
    finally:
        shutil.rmtree(scratch, True)
    if failures:
        print("quux15_kr260_param: FAILED, %d of the figures" % len(failures))
        return 1
    print("quux15_kr260_param: ok, every figure at every period")
    return 0


if __name__ == "__main__":
    sys.exit(main())
