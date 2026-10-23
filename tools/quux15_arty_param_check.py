#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Whether revision 15's Arty Z7-20 top level hands its modules the board's
figures, read at the instances.

    python3 tools/quux15_arty_param_check.py <the top's sources>

`boards/arty-z7-20/quux15_arty.sv` decides figures that no check of a module
can see, because each module's own check builds it with the figure directly.
As `tools/quux15_kr260_param_check.py` holds the Kria KR260's, this holds the
Arty's:

**THE MACHINE'S SIZE AND PLACE**: the cache's 4,096 words (Q-MP6), main
memory's 32M words and the two bases, main memory's at 0x1200_0000 and the
display's at 0x1C00_0000 (`cadr_ddr_map.sv`'s Arty rows), at the core; one
write ID, the port's tied zero; main memory's 512 units at the console face
(word 37).

**THE VIDEO CONTROLLER'S SIZE** (contract HD): the Arty's 1280 by 1024, at
the core (`VIDEO_W`, `VIDEO_H` and its frame buffer's `FB_WORDS`), at the
console face (word 39), and at the display output (`PIC_W`, `PIC_H`,
`WORDS_PER_LINE`), whose raster is VESA's 1280 by 1024 at 60 Hz, written here
apart from the module's defaults, and whose base is the display's.

**THE BOARD NAME** (contract HD): "Arty Z7-20", at the core (`BOARD_NAME`)
and packed as feature words 20-24 give it (`BOARD_NAME_WORDS`).

**THE PERIOD AND EVERY TIME IN CLOCKS** (A15b.12; the MP5a review's R9): for
each period asked, the MMCM's divide is the period at a 1,000 MHz VCO from
the board's 125 MHz; the core's `period` and the face's word 40 are it in
units of 0.5 ns; and the display's `SECOND_T` (a second, to the nearest
clock), the microcycle lamp's `HOLD_T` and the disk lamp's `DISK_LIT_T`
(2^22 ticks of 10 ns, rounded up) and the input's `MOUSE_STEP_T` (muir's
16,000 ns, rounded up) are computed here from the period, apart from the
top's arithmetic.  A top that left any of them at its tick count passes at
10 ns and is caught at every other period.

**THE BOARD'S PERIOD BY REVISION**: 50 ns at revision 15 and 60 ns at
revision 16, the top's own `PERIOD_NS` and the bitstream flow's default when
no period is asked, each held to the figure written here.

**THE VALUE IS READ AT THE INSTANCE, NOT INFERRED FROM THE TEXT**: Verilator
elaborates the top at each period, after a lint with `-Wall`, and writes its
tree as JSON, as `tools/machine_param_check.py` does for the other tops.

Exit status 0 when every figure agrees, 1 otherwise, each printed either way.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from machine_param_check import name_of, params_at_cell, walk  # noqa: E402
import ethernet_page_check  # noqa: E402

VERILATOR = os.environ.get("VERILATOR", "verilator")
TOP = "quux15_arty"
# The periods the board's fits are asked for (MP8 step 0: 44, 47, 48; the
# board's own, 50 at revision 15 and 60 at revision 16), and 10 ns, the tick,
# where a figure left at its tick count agrees by accident.
PERIODS = (10, 44, 47, 48, 50, 60)
# The board's period by revision, written here apart from the top and from
# the bitstream's flow: what a build that names no period gets.
OWN = {15: 50, 16: 60}
BITSTREAM_TCL = "boards/arty-z7-20/vivado/quux15_bitstream.tcl"
TCLSH = os.environ.get("TCLSH", "tclsh")
# Written here apart from the top: contract HD's video controller and board
# name, Q-MP6's cache, contract G2 §3's main memory, `cadr_ddr_map.sv`'s Arty
# bases, and VESA DMT's 1280 by 1024 at 60 Hz (`docs/display-output.md`).
VIDEO = (1280, 1024)
NAME = "Arty Z7-20"
CACHE_WORDS = 4096
MAIN_WORDS = 32 * 1024 * 1024
MAIN_BASE = 0x1200_0000
DISPLAY_BASE = 0x1C00_0000
RASTER = {"H_ACTIVE": 1280, "H_FRONT": 48, "H_SYNC": 112, "H_BACK": 248,
          "V_ACTIVE": 1024, "V_FRONT": 1, "V_SYNC": 3, "V_BACK": 38}

failures = []


def say(ok, what):
    print("quux15_arty_param: %s %s" % ("ok     " if ok else "FAILED ", what))
    if not ok:
        failures.append(what)


def run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def check(want, got, why, what):
    if got is None:
        say(False, "%s --- %s" % (what, why or "no such cell"))
    elif got != want:
        say(False, "%s --- it elaborates %s, want %s" % (
            what, ", ".join("%s=%d" % kv for kv in sorted(got.items())),
            ", ".join("%s=%d" % kv for kv in sorted(want.items()))))
    else:
        say(True, "%s: %s" % (what, ", ".join("%s=%d" % kv for kv in sorted(got.items()))))


def modules_of(tree):
    modules = {}
    walk(tree, lambda n: modules.__setitem__(n["addr"], n)
         if n.get("type") == "MODULE" else None)
    return modules


def the_top(tree):
    tops = [m for m in modules_of(tree).values() if m.get("origName") == TOP]
    return tops[0] if len(tops) == 1 else None


def cell_of(tree, name):
    top = the_top(tree)
    cells = []
    if top is not None:
        walk(top, lambda n: cells.append(n)
             if n.get("type") == "CELL" and n.get("name") == name else None)
    return cells[0] if len(cells) == 1 else None


def real_params_at_cell(tree, name, names):
    """The real-valued parameters `names` of the cell `name`, as written."""
    cell = cell_of(tree, name)
    if cell is None:
        return None
    mod = modules_of(tree).get(cell.get("modp"))
    values = {}

    def param(n):
        if n.get("type") == "VAR" and n.get("name") in names and n.get("isParam"):
            v = n.get("valuep") or []
            if len(v) == 1 and v[0].get("type") == "CONST":
                values[n["name"]] = float(v[0]["name"])
    walk(mod, param)
    return values if set(values) == set(names) else None


def pin_const(tree, name, pin):
    """The constant the cell `name`'s pin `pin` is tied to, or None."""
    cell = cell_of(tree, name)
    if cell is None:
        return None
    for p in cell.get("pinsp") or []:
        if p.get("name") == pin:
            e = p.get("exprp") or []
            if len(e) == 1 and e[0].get("type") == "CONST":
                return int(e[0]["name"].split("h")[-1], 16)
    return None


def top_param(tree, name):
    """A constant parameter of the top level itself."""
    top = the_top(tree)
    found = []
    if top is not None:
        for n in top.get("stmtsp") or []:
            if n.get("type") == "VAR" and n.get("name") == name and n.get("isParam"):
                v = n.get("valuep") or []
                if len(v) == 1 and v[0].get("type") == "CONST":
                    found.append(int(v[0]["name"].split("h")[-1], 16))
    return found[0] if len(found) == 1 else None


def at_period(period, sources, scratch, revision=15):
    base = [VERILATOR, "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7",
            "-Iboards/arty-z7-20", "--top-module", TOP, "-GPERIOD_NS=%d" % period,
            "-GREVISION=%d" % revision]
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
    at = "REVISION=%d, PERIOD_NS=%d" % (revision, period)
    ethernet_page_check.figures(tree, TOP, "u_gp0_split", revision, at, say)

    # The clock: the period at a 1,000 MHz VCO from 125 MHz.
    want = {"CLKIN1_PERIOD": 8.0, "CLKFBOUT_MULT_F": 8.0, "CLKOUT0_DIVIDE_F": float(period)}
    got = real_params_at_cell(tree, "u_mmcm", list(want))
    what = "%s, u_mmcm: 125 MHz x 8 / %d, the period" % (at, period)
    say(got == want, what if got == want else "%s --- it elaborates %s" % (what, got))
    # The period in units of 0.5 ns, at the core and at the face.
    got = pin_const(tree, "u_core", "period")
    what = "%s, u_core: the period pin %d half-nanoseconds" % (at, 2 * period)
    say(got == 2 * period, what if got == 2 * period else "%s --- it is tied to %s" % (what, got))
    want = {"PERIOD": 2 * period, "MAIN_UNITS": MAIN_WORDS >> 16, "VIDEO_W": w, "VIDEO_H": h}
    got, why = params_at_cell(tree, TOP, "u_face", list(want))
    check(want, got, why, "%s, u_face: words 37, 39 and 40" % at)

    # The times, from the period here.
    second = (10 ** 9 + period // 2) // period
    hold = -(-41_943_040 // period)
    step = -(-16_000 // period)
    want = dict(RASTER)
    want.update({"PIC_W": w, "PIC_H": h, "WORDS_PER_LINE": w // 32, "SPREAD": 0,
                 "SECOND_T": second, "BASE": DISPLAY_BASE})
    got, why = params_at_cell(tree, TOP, "u_display", list(want))
    check(want, got, why, "%s, u_display: the raster, the picture, its base and a second" % at)
    want = {"HOLD_T": hold}
    got, why = params_at_cell(tree, TOP, "u_lamp_microcycle", list(want))
    check(want, got, why, "%s, u_lamp_microcycle: the hold" % at)
    got = top_param(tree, "DISK_LIT_T")
    what = "%s, the disk lamp's stretch %d clocks" % (at, hold)
    say(got == hold, what if got == hold else "%s --- it is %s" % (what, got))
    want = {"MOUSE_STEP_T": step}
    got, why = params_at_cell(tree, TOP, "u_input", list(want))
    check(want, got, why, "%s, u_input: the mouse's step" % at)

    # The machine's size and place, the same at every period.
    want = {"VIDEO_W": w, "VIDEO_H": h, "FB_WORDS": w // 32 * h, "CACHE_WORDS": CACHE_WORDS,
            "MAIN_WORDS": MAIN_WORDS, "MAIN_BASE": MAIN_BASE, "DISPLAY_BASE": DISPLAY_BASE,
            "ONE_WRITE_ID": 1}
    got, why = params_at_cell(tree, TOP, "u_core", list(want))
    check(want, got, why, "%s, u_core: the cache, main memory, the bases, one write ID, the video controller" % at)

    # The board name: the top's literal at the core, and the five words it
    # packs, from the name here.
    what = "%s, u_core: the board name %r" % (at, NAME)
    got, why = params_at_cell(tree, TOP, "u_core", ["BOARD_NAME"])
    if got is None:
        say(False, "%s --- %s" % (what, why or "no such cell"))
    elif name_of(got["BOARD_NAME"]) != NAME:
        say(False, "%s --- it elaborates %r" % (what, name_of(got["BOARD_NAME"])))
    else:
        say(True, what)
    want = {"BOARD_NAME_WORDS": int.from_bytes(NAME.encode("ascii").ljust(20, b"\0"), "little")}
    what = "%s, u_core: feature words 20-24 hold %r" % (at, NAME)
    got, why = params_at_cell(tree, TOP, "u_core", list(want))
    if got is None:
        say(False, "%s --- %s" % (what, why or "no such cell"))
    elif got != want:
        say(False, "%s --- they hold %040x, want %040x" % (
            what, got["BOARD_NAME_WORDS"], want["BOARD_NAME_WORDS"]))
    else:
        say(True, what)


def own_period(sources, scratch, revision):
    """The top elaborated with no period given, and the bitstream's flow asked
    for none: each is the board's period at `revision`."""
    want = OWN[revision]
    base = [VERILATOR, "-Irtl/machine", "-Irtl/plumbing", "-Irtl/plumbing/xilinx7",
            "-Iboards/arty-z7-20", "--top-module", TOP, "-GREVISION=%d" % revision]
    mdir = tempfile.mkdtemp(dir=scratch)
    rc, out = run(base[:1] + ["--json-only", "-Mdir", mdir] + base[1:] + sources)
    if rc != 0:
        say(False, "REVISION=%d, the top's own period: the JSON dump failed:\n%s" % (revision, out.strip()))
        return
    with open(os.path.join(mdir, "V%s.tree.json" % TOP)) as f:
        tree = json.load(f)
    shutil.rmtree(mdir, True)
    got = top_param(tree, "PERIOD_NS")
    what = "REVISION=%d, the top's own PERIOD_NS is %d ns, the board's" % (revision, want)
    say(got == want, what if got == want else "%s --- it is %s" % (what, got))
    got = pin_const(tree, "u_core", "period")
    what = "REVISION=%d, the top's own period reaches u_core's period pin as %d" % (revision, 2 * want)
    say(got == 2 * want, what if got == 2 * want else "%s --- it is tied to %s" % (what, got))
    # The flow's own: its lines that set the revision and the period, run
    # with REVISION set and no PERIOD_NS, as Vivado would run them.
    with open(BITSTREAM_TCL) as f:
        lines = [l for l in f if l.startswith(("set revision ", "set period "))]
    script = os.path.join(scratch, "period_%d.tcl" % revision)
    with open(script, "w") as f:
        f.write("set ::env(REVISION) %d\nunset -nocomplain ::env(PERIOD_NS)\n" % revision)
        f.writelines(lines)
        f.write("puts $period\n")
    rc, out = run([TCLSH, script])
    what = "REVISION=%d, %s builds at %d ns when no period is asked" % (revision, BITSTREAM_TCL, want)
    say(rc == 0 and out.strip() == str(want), what if rc == 0 and out.strip() == str(want)
        else "%s --- it gives %r" % (what, out.strip()))


def main():
    sources = sys.argv[1:]
    if not sources:
        print(__doc__)
        return 2
    # The tree's own build/, which a copy that has run nothing else (a
    # mutation run selecting only this check) does not have yet.
    os.makedirs("build", exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="quux15_arty_param.", dir="build")
    try:
        for r in (15, 16):
            own_period(sources, scratch, r)
            for p in PERIODS:
                at_period(p, sources, scratch, r)
    finally:
        shutil.rmtree(scratch, True)
    if failures:
        print("quux15_arty_param: FAILED, %d of the figures" % len(failures))
        return 1
    print("quux15_arty_param: ok, every figure at every period")
    return 0


if __name__ == "__main__":
    sys.exit(main())
