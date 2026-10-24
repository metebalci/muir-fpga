#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Which machine each board's top level and flow builds.

    python3 tools/machine_param_check.py . [--make]

`MACHINE` is "cadr", MIT's machine, or "quux", the evolved CADR.  The CADR's
top levels, `cadr_arty`, `cadr_kr260` and `cadr_de25`, build the CADR and
nothing else; QUUX has its own top levels (`quux15_*`) and, on the Zynq
boards, its own Vivado flows.  This holds the CADR's top levels to the CADR's
parts, and the flows to the machine each is asked for.

**THE DEBUG CABLE IS THE CADR'S** (contract Q5), read in the elaborated tree
and not inferred from the text.  For each board and each configuration,
Verilator lints the top level with `-Wall` and writes its tree as JSON, and
in it the CADR has one cell each of the cable's connector, `cadr_dbg_cable`,
and of the join of its two debuggers, `cadr_dbg_join`, and one of the
register window, `cadr_debug_window`, on a board with a processing system;
and no assignment to one of the connector's eight pads is a bare high
impedance, the connector driving each through its enable.  The
configurations are the plain board and the memory board with its display,
which is the one a bitstream is built as.  In the same tree the console's
memory boards are the CADR's, 32 from 1 to 60, its word 39 names no video
controller, and the Kria KR260's display is built at the raster its check
holds, with the CADR's picture.

**AND THE FLOWS' OWN REFUSALS**, which run before any vendor tool is looked
for, so they can be run here: the Arty's and the Kria KR260's Vivado flows
build the CADR, from MIT's boot PROM, refuse a name that is not a machine,
and refuse `MACHINE=quux`, naming QUUX's own flow; the DE25-Nano's build and
program scripts refuse a name that is not a machine and accept both, take
QUUX with no `REVISION` or with the one this tree builds, and refuse any
other and a `REVISION` on the CADR; and the build script refuses QUUX beside
`FAULT=1`, because the fault bitstream carries no machine.

**AND THE DE25-NANO'S QUUX BUILDS AT ITS BINDING PERIOD FROM PROM 2002 BY
DEFAULT**, as the Kria KR260's and the Arty Z7-20's flows do: its
`build.sh`, asked for no period and no PROM, says 25 ns, the board's, and
`build/boot_prom.quux15.hex`; it takes the image `PROM` names; it holds the
image to `PROM_SHA256` when given, refusing one that differs and taking one
that agrees; it refuses a period it cannot run; and it refuses `PROM` on the
CADR.  With `--make`, which the Makefile passes and the mutation runner's
copy (which has no Makefile) does not, `make -n de25 MACHINE=quux` hands
`build.sh` the revision, the period 25, PROM 2002's image and that image's
digest, written here apart from the Makefile, and with `PROM` named, that
image and no digest.

WHAT THIS DOES NOT SAY.  It says nothing about what QUUX is: that is
`make check MACHINE=quux`, against muir's own QUUX.  It does not run Vivado
or Quartus, so it does not see what synthesis builds there; and it does not
check where either flow writes its build.

Exit status 0 when every case agrees, 1 otherwise, with each case's line
printed either way.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

VERILATOR = os.environ.get("VERILATOR", "verilator")
TCLSH = os.environ.get("TCLSH", "tclsh")

# The two packages the top levels import, which Verilator has to parse before
# the files that read them; everything else is found by module name in the
# include directories, as the vendor flows find it by globbing them.
PACKAGES = ["rtl/machine/cadr_tick_pkg.sv", "rtl/plumbing/cadr_ddr_map.sv"]

BOARDS = {
    "arty": {
        "top": "cadr_arty",
        "file": "boards/arty-z7-20/cadr_arty.sv",
        "dirs": ["rtl/machine", "rtl/plumbing", "rtl/plumbing/xilinx7",
                 "boards/arty-z7-20"],
        "defines": [],
        "stubs": ["tb/cadr_arty_stubs.sv", "tb/cadr_usr_access_stub.sv"],
        "configs": {
            "plain": ([], []),
            "DDR=1 HDMI=1": (["-GDDR=1", "-GHDMI=1"], ["tb/cadr_ps7_stub.sv"]),
        },
        # The debug cable's eight pads, Pmod JA.
        "pads": ["ja"],
    },
    "de25": {
        "top": "cadr_de25",
        "file": "boards/de25-nano/cadr_de25.sv",
        "dirs": ["rtl/machine", "rtl/plumbing", "rtl/plumbing/agilex5",
                 "boards/de25-nano"],
        "defines": ["-DCADR_DDR_MAP_DE25_NANO"],
        "stubs": ["tb/cadr_de25_stubs.sv"],
        "configs": {
            "plain": ([], []),
            "DDR=1 HDMI=1": (["-DCADR_DE25_DDR", "-DCADR_DE25_HDMI"], []),
        },
        # The debug cable's eight pads, JP1 pins 31 to 38.
        "pads": ["jp1_pin3%d" % i for i in range(1, 9)],
    },
    # The Kria KR260, on its own memory map, with the `PS8`'s stub for the
    # board with the processing system.
    "kr260": {
        "top": "cadr_kr260",
        "file": "boards/kria-kr260/cadr_kr260.sv",
        "dirs": ["rtl/machine", "rtl/plumbing", "rtl/plumbing/xilinx7",
                 "boards/kria-kr260"],
        "defines": ["-DCADR_DDR_MAP_KR260"],
        "stubs": ["tb/cadr_arty_stubs.sv", "tb/cadr_usr_access_stub.sv",
                  "tb/cadr_kr260_stubs.sv"],
        "configs": {
            "plain": ([], []),
            "DDR=1": (["-GDDR=1"], ["tb/cadr_ps8_stub.sv"]),
        },
        "pads": ["pmod1"],
    },
}

# A name that is not a machine, and close enough to one to be a typing slip.
NOT_A_MACHINE = "cdr"

# The one revision QUUX is built at, which the DE25-Nano's scripts take.
QUUX_REVISION = "16"

# The DE25-Nano's QUUX by default: the board's period, and PROM 2002, its
# image's path and digest (the Makefile's `QUUX15_PROM_2002_SHA256`, written
# again here).
DE25_Q15_PERIOD_NS = "25"
DE25_Q15_PROM = "build/boot_prom.quux15.hex"
DE25_Q15_PROM_SHA256 = "2b27752f9327d5ed3e61c7af39777d8ebf7e6ab971f6fdaa2e56bfe1c88cdb1c"
DE25_Q15_TEST_PROM = "build/quux15_transfer_prom.hex"

failures = []
log = []


def say(ok, what):
    """One case's line.  A tool's own output under it is quoted with `| `,
    so that a Verilator warning in the evidence is never read as the verdict
    by something scanning for one."""
    head, _, rest = what.partition("\n")
    log.append("machine: %s  %s" % ("ok    " if ok else "FAILED", head))
    log.extend("    | " + line for line in rest.split("\n") if rest)
    if not ok:
        failures.append(head)


def run(cmd, env=None):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       env=env)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def verilator(board, config, mode, mdir=None):
    spec = BOARDS[board]
    gens, extra = spec["configs"][config]
    cmd = [VERILATOR, mode]
    if mode == "--lint-only":
        cmd.append("-Wall")
    for d in spec["dirs"]:
        cmd.append("-I" + d)
    cmd += spec["defines"] + gens
    if mdir is not None:
        cmd += ["-Mdir", mdir]
    cmd += ["--top-module", spec["top"]]
    cmd += spec["stubs"] + extra + PACKAGES + [spec["file"]]
    return run(cmd)


def walk(node, fn):
    if isinstance(node, dict):
        fn(node)
        for v in node.values():
            walk(v, fn)
    elif isinstance(node, list):
        for v in node:
            walk(v, fn)


def params_at_cell(tree, top, cell, names):
    """The constant parameters `names` of the module the cell `cell` inside
    `<top>` became, or None and why.  None, None when there is no such cell."""
    modules = {}
    walk(tree, lambda n: modules.__setitem__(n["addr"], n)
         if n.get("type") == "MODULE" else None)
    tops = [m for m in modules.values() if m.get("origName") == top]
    cells = []
    if len(tops) == 1:
        walk(tops[0], lambda n: cells.append(n)
             if n.get("type") == "CELL" and n.get("name") == cell else None)
    if not cells:
        return None, None
    if len(cells) != 1:
        return None, "%d cells %s in %s" % (len(cells), cell, top)
    mod = modules.get(cells[0].get("modp"))
    values = {}

    def param(n):
        if n.get("type") == "VAR" and n.get("name") in names and n.get("isParam"):
            v = n.get("valuep") or []
            if len(v) == 1 and v[0].get("type") == "CONST":
                values[n["name"]] = int(v[0]["name"].split("h")[-1], 16)
    walk(mod, param)
    if set(values) != set(names):
        return None, "no constant %s in %s" % (", ".join(sorted(set(names) - set(values))), mod.get("name"))
    return values, None


# **THE DEBUG CABLE IS THE CADR'S** (contract Q5): its connector, the
# join of its two debuggers and the register window that carries it on the
# general-purpose port.  The CADR builds the connector and the join on every
# board and the window on every board with a processing system.
CABLE_MODULES = ("cadr_dbg_cable", "cadr_dbg_join", "cadr_debug_window")


def name_of(value):
    """A board name parameter's characters: the literal is right-justified,
    so the bytes from the highest that is not zero down to bit 0.  QUUX's
    top levels' checks read their names with it."""
    b = value.to_bytes(64, "big").lstrip(b"\0")
    return b.decode("ascii", "replace")


def cable_cells(tree):
    """How many cells of each of the cable's modules the tree elaborates."""
    modules = {}
    walk(tree, lambda n: modules.__setitem__(n["addr"], n)
         if n.get("type") == "MODULE" else None)
    counts = dict((m, 0) for m in CABLE_MODULES)

    def cell(n):
        if n.get("type") == "CELL":
            mod = modules.get(n.get("modp"))
            name = mod.get("origName") if mod else None
            if name in counts:
                counts[name] += 1
    walk(tree, cell)
    return counts


def pad_writes(tree, pads):
    """Every continuous assignment to one of the cable's pads, each as the
    number of bits it writes and whether what it writes is high impedance
    and nothing else."""
    writes = []

    def assign(n):
        if n.get("type") != "ASSIGNW":
            return
        lhs = (n.get("lhsp") or [None])[0] or {}
        ref = lhs
        if ref.get("type") == "SEL":
            ref = (ref.get("fromp") or [{}])[0]
        if ref.get("type") != "VARREF" or ref.get("name") not in pads:
            return
        rhs = (n.get("rhsp") or [None])[0] or {}
        const = rhs.get("name", "") if rhs.get("type") == "CONST" else ""
        width, _, digits = const.partition("'")
        z = bool(const) and digits[:1] == "b" and set(digits[1:]) == {"z"}
        writes.append((int(width) if z else 0, z))
    walk(tree, assign)
    return writes


def cable_at_top(board, config, tree):
    """The CADR carries the cable's modules, and its connector drives the
    cable's pads, every one through its enable, so no assignment to a pad is
    a bare high impedance."""
    top = BOARDS[board]["top"]
    want = {"cadr_dbg_cable": 1, "cadr_dbg_join": 1,
            "cadr_debug_window": 1 if "DDR" in config else 0}
    got = cable_cells(tree)
    what = "%s, %s: the debug cable's cells are %s" % (
        top, config, ", ".join("%s %d" % (m, want[m]) for m in CABLE_MODULES))
    if got != want:
        say(False, "%s --- the tree has %s" % (
            what, ", ".join("%s %d" % (m, got[m]) for m in CABLE_MODULES)))
    else:
        say(True, what)
    writes = pad_writes(tree, BOARDS[board]["pads"])
    floated = sum(bits for bits, z in writes if z)
    what = "%s, %s: the connector drives the cable's pads" % (top, config)
    if len(writes) > 0 and floated == 0:
        say(True, what)
    else:
        say(False, "%s --- %d assignment(s) to them, %d of them high impedance over %d bit(s)"
            % (what, len(writes), sum(1 for _, z in writes if z), floated))


def console_at_top(board, config, tree):
    """The console's memory boards are the CADR's, 32 from 1 to 60, and its
    word 39 names no video controller."""
    top = BOARDS[board]["top"]
    want = {"MEM_BOARDS_DEFAULT": 32, "MEM_BOARDS_MAX": 60,
            "VIDEO_WIDTH": 0, "VIDEO_HEIGHT": 0}
    what = "%s, %s: u_console's memory boards come up at 32 and take 1 to 60, " \
           "and its word 39 names no video controller" % (top, config)
    got, why = params_at_cell(tree, top, "u_console", list(want))
    if got is None and why is None:
        if config.startswith("DDR"):
            say(False, "%s --- no u_console in a build with the processing system" % what)
        return
    if got is None:
        say(False, "%s --- %s" % (what, why))
    elif got != want:
        say(False, "%s --- it has %s" % (what, got))
    else:
        say(True, what)


def kr260_raster(config, tree):
    """**THE KRIA KR260'S DISPLAY IS BUILT AT THE RASTER ITS CHECK HOLDS.**
    `build/display_out_kr260.pass` builds `cadr_display_out` with the figures
    in `boards/kria-kr260/display_raster.mk` and holds the eight edges at them;
    this holds that the board's top level hands its `u_display` the same
    figures, read at the instance, and the CADR's own picture."""
    if config != "DDR=1":
        return
    top = BOARDS["kr260"]["top"]
    with open("boards/kria-kr260/display_raster.mk") as f:
        text = f.read()
    m = re.search(r"^DISPLAY_KR260_G\s*:=((?:.*\\\n)*.*)$", text, re.M)
    want = {}
    if m:
        for k, v in re.findall(r"-G(\w+)=(\d+)", m.group(1)):
            want[k] = int(v)
    raster = ["H_ACTIVE", "H_FRONT", "H_SYNC", "H_BACK",
              "V_ACTIVE", "V_FRONT", "V_SYNC", "V_BACK"]
    what = "%s, %s: u_display's raster is display_raster.mk's" % (top, config)
    if sorted(want) != sorted(raster):
        say(False, "%s --- display_raster.mk names %s" % (what, sorted(want)))
        return
    pic = {"PIC_W": 768, "PIC_H": 963, "WORDS_PER_LINE": 24, "SPREAD": 1}
    want.update(pic)
    got, why = params_at_cell(tree, top, "u_display", list(want))
    if got is None:
        say(False, "%s --- %s" % (what, why or "no u_display"))
    elif got != want:
        say(False, "%s --- it elaborates %s, want %s" % (
            what, ", ".join("%s=%d" % kv for kv in sorted(got.items())),
            ", ".join("%s=%d" % kv for kv in sorted(want.items()))))
    else:
        say(True, "%s, and the CADR's picture %dx%d" % (what, pic["PIC_W"], pic["PIC_H"]))


def board_top(board, config, scratch):
    """The top level lints clean, and its elaborated tree is the CADR's."""
    top = BOARDS[board]["top"]
    what = "%s, %s: the top level lints clean" % (top, config)
    rc, out = verilator(board, config, "--lint-only")
    if rc != 0:
        say(False, "%s --- the lint failed:\n%s" % (what, out.strip()))
        return
    say(True, what)
    mdir = tempfile.mkdtemp(dir=scratch)
    rc, out = verilator(board, config, "--json-only", mdir)
    if rc != 0:
        say(False, "%s, %s: the JSON dump failed:\n%s" % (top, config, out.strip()))
        return
    with open(os.path.join(mdir, "V%s.tree.json" % top)) as f:
        tree = json.load(f)
    shutil.rmtree(mdir, True)
    cable_at_top(board, config, tree)
    console_at_top(board, config, tree)
    if board == "kr260":
        kr260_raster(config, tree)


def flow(what, cmd, env_add, rc_want, has, lacks):
    env = dict(os.environ)
    for name in ("MACHINE", "REVISION", "PERIOD_NS", "PROM", "PROM_SHA256", "FAULT"):
        env.pop(name, None)
    env.update(env_add)
    rc, out = run(cmd, env)
    wrong = []
    if rc_want is not None and rc != rc_want:
        wrong.append("it exited %d" % rc)
    wrong += ["no line says \"%s\"" % h for h in has if h not in out]
    wrong += ["a line says \"%s\"" % h for h in lacks if h in out]
    if wrong:
        say(False, "%s --- %s:\n%s" % (what, ", ".join(wrong), out.strip()))
    else:
        say(True, what)


def make_flow(what, make_args, has, lacks):
    """`make -s -n` of the DE25-Nano's flow, joined across its continuation
    lines: what it hands `build.sh`, each of `has` on the line that runs it
    and none of `lacks`.  PROM 2002's image is not remade (`-o`): nothing in
    `make check` reads it, and `-n` runs nothing."""
    env = dict(os.environ)
    for name in ("MACHINE", "REVISION", "PERIOD_NS", "PROM", "PROM_SHA256", "MAKEFLAGS", "MFLAGS"):
        env.pop(name, None)
    rc, out = run(["make", "-s", "-n", "-o", DE25_Q15_PROM, "de25"] + make_args, env)
    line = [l for l in out.replace("\\\n", " ").split("\n") if "boards/de25-nano/quartus/build.sh" in l]
    wrong = []
    if rc != 0:
        wrong.append("make exited %d" % rc)
    if len(line) != 1:
        wrong.append("%d lines run build.sh" % len(line))
    else:
        words = line[0].split()
        wrong += ["the line has no %s" % h for h in has if h not in words]
        wrong += ["the line has %s" % h for h in lacks if any(w.startswith(h) for w in words)]
    if wrong:
        say(False, "%s --- %s:\n%s" % (what, ", ".join(wrong), out.strip()))
    else:
        say(True, what)


def main():
    args = sys.argv[1:]
    with_make = "--make" in args
    args = [a for a in args if a != "--make"]
    if len(args) != 1:
        sys.exit("usage: machine_param_check.py <repository root> [--make]")
    os.chdir(args[0])
    os.makedirs("build", exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="machine_param.", dir="build")
    try:
        for board, spec in sorted(BOARDS.items()):
            for config in spec["configs"]:
                board_top(board, config, scratch)

        # The Zynq boards' Vivado flows.  Every OUTDIR is under the scratch
        # directory, so a flow that failed to refuse writes nothing anywhere
        # else.
        out = lambda name: os.path.join(scratch, name)
        for name, cmd, flow_dir in (
                ("the Arty's", [TCLSH, "boards/arty-z7-20/vivado/bitstream.tcl"], "boards/arty-z7-20/vivado"),
                ("the Kria KR260's", [TCLSH, "boards/kria-kr260/vivado/bitstream.tcl"], "boards/kria-kr260/vivado")):
            flow("%s Vivado flow refuses MACHINE=%s" % (name, NOT_A_MACHINE), cmd,
                 {"MACHINE": NOT_A_MACHINE, "OUTDIR": out("a")}, 1,
                 ["BIT: FAILED --- MACHINE=%s is not a machine" % NOT_A_MACHINE],
                 ["BIT: the machine is"])
            flow("%s Vivado flow refuses MACHINE=quux, naming QUUX's flow" % name, cmd,
                 {"MACHINE": "quux", "OUTDIR": out("quux")}, 1,
                 ["BIT: FAILED --- MACHINE=quux is not built by this flow",
                  "%s/quux15_bitstream.tcl" % flow_dir],
                 ["BIT: the machine is"])
            for env_add, asked in (({"MACHINE": "cadr"}, "MACHINE=cadr"), ({}, "no MACHINE")):
                flow("%s Vivado flow takes %s as the CADR, with MIT's PROM" % (name, asked), cmd,
                     dict(env_add, OUTDIR=out("cadr")), None,
                     ["BIT: the machine is cadr\n", "BIT: the boot PROM is build/boot_prom.hex\n"],
                     ["FAILED --- MACHINE"])

        nowhere = {"QUARTUS_ROOTDIR": out("no-quartus")}
        for script, who in (("build.sh", "de25"), ("program.sh", "de25-program")):
            cmd = ["sh", "boards/de25-nano/quartus/" + script, "x"]
            flow("the DE25-Nano's %s refuses MACHINE=%s" % (script, NOT_A_MACHINE),
                 cmd, dict(nowhere, MACHINE=NOT_A_MACHINE), 1,
                 ["%s: REFUSED: MACHINE is '%s'" % (who, NOT_A_MACHINE)], [])
            # Accepted, and refused only later for the Quartus that is not
            # there.
            for value in ("cadr", "quux"):
                flow("the DE25-Nano's %s takes MACHINE=%s" % (script, value),
                     cmd, dict(nowhere, MACHINE=value), 1,
                     ["%s: REFUSED:" % who], ["REFUSED: MACHINE is", "REFUSED: REVISION"])
            flow("the DE25-Nano's %s takes QUUX at REVISION=%s" % (script, QUUX_REVISION), cmd,
                 dict(nowhere, MACHINE="quux", REVISION=QUUX_REVISION), 1,
                 ["%s: REFUSED:" % who], ["REFUSED: REVISION"])
            for other in ("15", "17"):
                flow("the DE25-Nano's %s refuses QUUX at REVISION=%s" % (script, other), cmd,
                     dict(nowhere, MACHINE="quux", REVISION=other), 1,
                     ["%s: REFUSED: REVISION is not taken" % who], [])
            flow("the DE25-Nano's %s refuses REVISION on the CADR" % script, cmd,
                 dict(nowhere, MACHINE="cadr", REVISION=QUUX_REVISION), 1,
                 ["%s: REFUSED: REVISION is QUUX's, and MACHINE=cadr" % who], [])

        cmd = ["sh", "boards/de25-nano/quartus/build.sh", "x"]
        flow("the DE25-Nano's build.sh refuses QUUX at a period it cannot run", cmd,
             dict(nowhere, MACHINE="quux", PERIOD_NS="9.5"), 1,
             ["de25: REFUSED: PERIOD_NS is 9.5; QUUX runs at 10 to 63.5 ns"], [])
        # QUUX by default: the binding fit's period and PROM 2002.
        q = dict(nowhere, MACHINE="quux")
        flow("the DE25-Nano's build.sh builds QUUX at %s ns from PROM 2002 by default"
             % DE25_Q15_PERIOD_NS, cmd, q, 1,
             ["de25: QUUX at %s ns:" % DE25_Q15_PERIOD_NS,
              "de25: the boot PROM is %s\n" % DE25_Q15_PROM], [])
        flow("the DE25-Nano's build.sh takes the boot PROM PROM names on QUUX", cmd,
             dict(q, PROM=DE25_Q15_TEST_PROM), 1,
             ["de25: the boot PROM is %s\n" % DE25_Q15_TEST_PROM], ["the boot PROM is %s" % DE25_Q15_PROM])
        image = out("not-prom-2002.hex")
        with open(image, "w") as f:
            f.write("0000000000000000\n")
        with open(image, "rb") as f:
            image_sha = hashlib.sha256(f.read()).hexdigest()
        flow("the DE25-Nano's build.sh refuses a boot PROM whose digest is not PROM_SHA256's", cmd,
             dict(q, PROM=image, PROM_SHA256=DE25_Q15_PROM_SHA256), 1,
             ["de25: REFUSED: %s's sha256 is %s, and PROM_SHA256 is %s" % (image, image_sha, DE25_Q15_PROM_SHA256)],
             ["PROM_SHA256's"])
        flow("the DE25-Nano's build.sh takes a boot PROM whose digest is PROM_SHA256's", cmd,
             dict(q, PROM=image, PROM_SHA256=image_sha), 1,
             ["de25: the boot PROM's sha256 is %s, PROM_SHA256's\n" % image_sha], ["and PROM_SHA256 is"])
        flow("the DE25-Nano's build.sh refuses PROM on the CADR", cmd,
             dict(nowhere, MACHINE="cadr", PROM=DE25_Q15_TEST_PROM), 1,
             ["de25: REFUSED: PROM=%s names QUUX's boot PROM" % DE25_Q15_TEST_PROM], [])
        if with_make:
            q_make = ["MACHINE=quux", "DDR=1", "HDMI=1"]
            make_flow("make de25 MACHINE=quux hands build.sh REVISION=%s, %s ns and PROM 2002 with its digest"
                      % (QUUX_REVISION, DE25_Q15_PERIOD_NS), q_make,
                      ["REVISION=%s" % QUUX_REVISION, "PERIOD_NS=%s" % DE25_Q15_PERIOD_NS,
                       "PROM=%s" % DE25_Q15_PROM, "PROM_SHA256=%s" % DE25_Q15_PROM_SHA256], [])
            make_flow("make de25 MACHINE=quux PROM=%s hands build.sh that image and no digest" % DE25_Q15_TEST_PROM,
                      q_make + ["PROM=%s" % DE25_Q15_TEST_PROM],
                      ["PERIOD_NS=%s" % DE25_Q15_PERIOD_NS, "PROM=%s" % DE25_Q15_TEST_PROM], ["PROM_SHA256="])
            make_flow("make de25 MACHINE=cadr hands build.sh no REVISION, period or PROM",
                      ["MACHINE=cadr", "DDR=1", "HDMI=1"], ["MACHINE=cadr"],
                      ["REVISION=", "PERIOD_NS=", "PROM="])
        # A fault build carries no machine, so QUUX beside it is refused, and
        # the CADR, the default, is taken as far as the missing Quartus.
        flow("the DE25-Nano's build.sh refuses FAULT=1 with MACHINE=quux", cmd,
             dict(nowhere, FAULT="1", MACHINE="quux"), 1,
             ["de25: REFUSED: FAULT=1 takes no MACHINE=quux"], [])
        flow("the DE25-Nano's build.sh takes FAULT=1 with MACHINE=cadr", cmd,
             dict(nowhere, FAULT="1", MACHINE="cadr"), 1,
             ["de25: REFUSED:"], ["takes no MACHINE"])
    finally:
        shutil.rmtree(scratch, True)
    # The failures first, each on one line, and then every case with its
    # evidence: the first line of the output is the verdict.
    for head in failures:
        print("FAILED: %s" % head)
    print("\n".join(log))
    if failures:
        print("machine: FAILED, %d of the cases above" % len(failures))
        return 1
    print("machine: every board's CADR top level is the CADR's, and the flows refuse what they must")
    return 0


if __name__ == "__main__":
    sys.exit(main())
