#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Whether the machine a board is built as reaches `cadr_machine`.

    python3 tools/machine_param_check.py .

`MACHINE` is "cadr", MIT's machine, or "quux", the evolved CADR.  Each board's
top level takes it as a parameter and hands it to `cadr_machine`, and the
board flows set it from the make variable of the same name.  A top level that
dropped it on the floor would build the CADR under the other name, and every
check of the board itself would stay green: what holds QUUX is the machine's
own checks, which build `cadr_machine` with the value directly.  This asks the
question of the top levels.

**THE VALUE IS READ AT THE INSTANCE, NOT INFERRED FROM THE TEXT.**  For each
board, each configuration and each value, Verilator elaborates the top level
and writes its tree as JSON, and this reads the parameter of the module that
the top's `u_machine` cell was elaborated into.  The same command is first
run as a lint with `-Wall`, so the value checked is the value of a design
that lints clean.  The configurations are the plain board and the memory
board with its display, which is the one a bitstream is built as.

**AND A NAME THAT IS NEITHER MUST STOP ELABORATION AT `u_machine`.**  A
near miss, "cdr", handed to the Arty's and the DE25-Nano's top levels must
fail with `cadr_machine`'s own message, in the instance `<top>.u_machine`.
That is the parameter's path shown a second way, by the machine refusing it.

**THE CORA Z7-07S BUILDS THE CADR ONLY.**  Its default reaches `u_machine`
as "cadr", and "quux" must stop elaboration with its top level's own
message.  Its Vivado flow must refuse `MACHINE=quux` before it writes
anything.

**AND THE FLOWS' OWN REFUSALS**, which run before any vendor tool is looked
for, so they can be run here: the Arty's Vivado flow refuses a name that is
not a machine and a QUUX build into a directory that does not say quux, and
accepts both machines as far as its first Vivado command; the DE25-Nano's
build and program scripts refuse a name that is not a machine and accept
both, and the build script refuses QUUX beside `FAULT=1`, because the fault
bitstream carries no machine.

**AND THE WORD, `WORD_BITS`, THE SAME WAY** (contract G2): 40 is QUUX
revision 13.  On the Arty's and the DE25-Nano's memory board with its
display, `MACHINE=quux WORD_BITS=40` lints clean and `u_machine` elaborates
`WORD_BITS` 40, and no `WORD_BITS` elaborates 32; and the file device's
page, `u_fd_face`, names the revision by its IDENT, "QF13" at 40 and "QFD9"
below.  The Arty's flow refuses a
width that is not a word, 40 on the CADR, and a directory that says `quux13`
for any build but revision 13's or does not for revision 13's, and takes
revision 13 into one that does; the DE25-Nano's two scripts refuse a width
that is not a word and 40 on the CADR, and take revision 13.

**AND THE DEBUG CABLE IS THE CADR'S ALONE** (contract Q5).  In the same
elaborated tree, the CADR has one cell each of the cable's connector,
`cadr_dbg_cable`, and of the join of its two debuggers, `cadr_dbg_join`, and
one of the register window, `cadr_debug_window`, on a board with a processing
system; QUUX has none of the three.  And the connector's eight pads: on the
CADR no assignment to one is a bare high impedance, the connector driving each
through its enable, and on QUUX every assignment to one is, over all eight
bits, so the pads are inputs nothing drives and their pull-downs hold them.

WHAT THIS DOES NOT SAY.  It says nothing about what QUUX is: that is
`make check MACHINE=quux`, against muir's own QUUX.  It does not run Vivado or Quartus, so it does not see
the generic reach synthesis there; `boards/de25-nano/quartus/build.sh` reads
the value back out of Quartus's synthesis report, and the Arty's flow has no
such read-back.  It does not check where either flow writes its build.

Exit status 0 when every case agrees, 1 otherwise, with each case's line
printed either way.
"""

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
        "machines": ["cadr", "quux"],
        # The debug cable's eight pads, Pmod JA.
        "pads": ["ja"],
        # QUUX's K by the word: revision 12's four, and revision 13's five,
        # the machine's clock left at 100 MHz so that its timers count true
        # time (`cadr_arty.sv`, `SYNC_K13`).
        "sync_k": {32: 4, 40: 5},
        # Revision 13's most memory boards: what the board's reservation holds
        # (`cadr_ddr_map.sv`, 32M words), written here apart from it.
        "boards13_max": 512,
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
        "machines": ["cadr", "quux"],
        # The debug cable's eight pads, JP1 pins 31 to 38.
        "pads": ["jp1_pin3%d" % i for i in range(1, 9)],
        "sync_k": {32: 4, 40: 4},
        # 64M words of room, and muir's most is 1,024 boards.
        "boards13_max": 1024,
    },
    "cora": {
        "top": "cadr_cora",
        "file": "boards/cora-z7-07s/cadr_cora.sv",
        "dirs": ["rtl/machine", "rtl/plumbing", "rtl/plumbing/xilinx7",
                 "boards/cora-z7-07s"],
        "defines": [],
        "stubs": ["tb/cadr_arty_stubs.sv", "tb/cadr_usr_access_stub.sv"],
        "configs": {
            "plain": ([], []),
            "DDR=1": (["-GDDR=1"], ["tb/cadr_ps7_stub.sv"]),
        },
        "machines": ["cadr"],
        "pads": ["ja"],
    },
    # The Kria KR260: the CADR, and QUUX at revision 13 alone (contract G2,
    # the KR260 port's K6), on its own memory map, with the `PS8`'s stub for
    # the board with the processing system.  `machines` is what the plain
    # sweep builds with no word; QUUX is swept at 40 bits by `word_reaches`.
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
        "machines": ["cadr"],
        "pads": ["pmod1"],
        # Revision 13 at four ticks, `SYNC_K13`; there is no revision 12.
        "sync_k": {40: 4},
        # Revision 13's room on this board: 32M words.
        "boards13_max": 512,
    },
}

# A name that is not a machine, and close enough to one to be a typing slip.
NOT_A_MACHINE = "cdr"

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


def verilator(board, config, value, mode, mdir=None, word_bits=None):
    spec = BOARDS[board]
    gens, extra = spec["configs"][config]
    cmd = [VERILATOR, mode]
    if mode == "--lint-only":
        cmd.append("-Wall")
    for d in spec["dirs"]:
        cmd.append("-I" + d)
    cmd += spec["defines"] + gens
    if value is not None:
        cmd.append('-GMACHINE="%s"' % value)
    if word_bits is not None:
        cmd.append("-GWORD_BITS=%d" % word_bits)
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


def machine_at_instance(tree, top):
    """The MACHINE parameter of the module `<top>.u_machine` became."""
    modules = {}
    walk(tree, lambda n: modules.__setitem__(n["addr"], n)
         if n.get("type") == "MODULE" else None)
    tops = [m for m in modules.values() if m.get("origName") == top]
    if len(tops) != 1:
        return None, "%d modules named %s in the tree" % (len(tops), top)
    cells = []
    walk(tops[0], lambda n: cells.append(n)
         if n.get("type") == "CELL" and n.get("name") == "u_machine" else None)
    if len(cells) != 1:
        return None, "%d cells named u_machine in %s" % (len(cells), top)
    mod = modules.get(cells[0].get("modp"))
    if mod is None or mod.get("origName") != "cadr_machine":
        return None, "%s.u_machine is not a cadr_machine" % top
    values = []

    def param(n):
        if n.get("type") == "VAR" and n.get("name") == "MACHINE" \
                and n.get("isParam"):
            v = n.get("valuep") or []
            if len(v) == 1 and v[0].get("type") == "CONST":
                values.append(v[0]["name"].replace('\\"', "").strip('"'))
            else:
                values.append(None)
    walk(mod, param)
    if len(values) != 1 or values[0] is None:
        return None, "no constant MACHINE parameter in %s" % mod.get("name")
    return values[0], None


def word_bits_at_instance(tree, top):
    """The WORD_BITS parameter of the module `<top>.u_machine` became."""
    modules = {}
    walk(tree, lambda n: modules.__setitem__(n["addr"], n)
         if n.get("type") == "MODULE" else None)
    tops = [m for m in modules.values() if m.get("origName") == top]
    cells = []
    if len(tops) == 1:
        walk(tops[0], lambda n: cells.append(n)
             if n.get("type") == "CELL" and n.get("name") == "u_machine" else None)
    if len(cells) != 1:
        return None, "no one u_machine in %s" % top
    mod = modules.get(cells[0].get("modp"))
    values = []

    def param(n):
        if n.get("type") == "VAR" and n.get("name") == "WORD_BITS" and n.get("isParam"):
            v = n.get("valuep") or []
            values.append(v[0]["name"] if len(v) == 1 and v[0].get("type") == "CONST" else None)
    walk(mod, param)
    if len(values) != 1 or values[0] is None:
        return None, "no constant WORD_BITS in %s" % mod.get("name")
    # Verilator writes a constant as 32'h28 or 32'sh28.
    return int(values[0].split("h")[-1], 16), None


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


def boards_at_console(board, config, asked, rev13, tree):
    """The console's memory boards are the machine's: the CADR's and revision
    12's 32 from 1 to 60, revision 13's 512 from 1 to the board's most."""
    top = BOARDS[board]["top"]
    want = {"MEM_BOARDS_DEFAULT": 512 if rev13 else 32,
            "MEM_BOARDS_MAX": BOARDS[board]["boards13_max"] if rev13 else 60}
    what = "%s, %s, %s: u_console's memory boards come up at %d and take 1 to %d" % (
        top, config, asked, want["MEM_BOARDS_DEFAULT"], want["MEM_BOARDS_MAX"])
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


def fd_ident_at_instance(tree, top):
    """The IDENT parameter of the module the file device's page, the cell
    `u_fd_face` in `<top>`, became."""
    modules = {}
    walk(tree, lambda n: modules.__setitem__(n["addr"], n)
         if n.get("type") == "MODULE" else None)
    tops = [m for m in modules.values() if m.get("origName") == top]
    cells = []
    if len(tops) == 1:
        walk(tops[0], lambda n: cells.append(n)
             if n.get("type") == "CELL" and n.get("name") == "u_fd_face" else None)
    if len(cells) != 1:
        return None, "no one u_fd_face in %s" % top
    mod = modules.get(cells[0].get("modp"))
    values = []

    def param(n):
        if n.get("type") == "VAR" and n.get("name") == "IDENT" and n.get("isParam"):
            v = n.get("valuep") or []
            values.append(v[0]["name"] if len(v) == 1 and v[0].get("type") == "CONST" else None)
    walk(mod, param)
    if len(values) != 1 or values[0] is None:
        return None, "no constant IDENT in %s" % mod.get("name")
    return int(values[0].split("h")[-1], 16), None


# **THE DEBUG CABLE IS THE CADR'S ALONE** (contract Q5): its connector, the
# join of its two debuggers and the register window that carries it on the
# general-purpose port.  The CADR builds the connector and the join on every
# board and the window on every board with a processing system; QUUX builds
# none of the three.
CABLE_MODULES = ("cadr_dbg_cable", "cadr_dbg_join", "cadr_debug_window")


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


def cable_at_top(board, config, asked, machine, tree):
    """The CADR carries the cable's modules and QUUX none of them."""
    top = BOARDS[board]["top"]
    if machine == "cadr":
        want = {"cadr_dbg_cable": 1, "cadr_dbg_join": 1,
                "cadr_debug_window": 1 if "DDR" in config else 0}
    else:
        want = dict((m, 0) for m in CABLE_MODULES)
    got = cable_cells(tree)
    what = "%s, %s, %s: the debug cable's cells are %s" % (
        top, config, asked,
        ", ".join("%s %d" % (m, want[m]) for m in CABLE_MODULES))
    if got != want:
        say(False, "%s --- the tree has %s" % (
            what, ", ".join("%s %d" % (m, got[m]) for m in CABLE_MODULES)))
    else:
        say(True, what)
    # **AND THE PADS.**  On the CADR the connector drives them, every one
    # through its enable, so no assignment to a pad is a bare high impedance;
    # on QUUX every assignment to one is, and they cover the eight bits, so
    # the pads are inputs nothing drives and their pull-downs hold them.
    writes = pad_writes(tree, BOARDS[board]["pads"])
    floated = sum(bits for bits, z in writes if z)
    if machine == "cadr":
        what = "%s, %s, %s: the connector drives the cable's pads" % (top, config, asked)
        ok = len(writes) > 0 and floated == 0
    else:
        what = "%s, %s, %s: the cable's 8 pads are left undriven" % (top, config, asked)
        ok = len(writes) > 0 and all(z for _, z in writes) and floated == 8
    if ok:
        say(True, what)
    else:
        say(False, "%s --- %d assignment(s) to them, %d of them high impedance over %d bit(s)"
            % (what, len(writes), sum(1 for _, z in writes if z), floated))


def word_reaches(board, config, bits, scratch):
    """QUUX at `bits` (None: not given, so 32) lints clean and is the width
    at u_machine."""
    top = BOARDS[board]["top"]
    want = bits if bits is not None else 32
    asked = "WORD_BITS=%d" % bits if bits is not None else "no WORD_BITS"
    what = "%s, %s, MACHINE=quux, %s: u_machine elaborates WORD_BITS %d" % (top, config, asked, want)
    rc, out = verilator(board, config, "quux", "--lint-only", word_bits=bits)
    if rc != 0:
        say(False, "%s --- the lint failed:\n%s" % (what, out.strip()))
        return
    mdir = tempfile.mkdtemp(dir=scratch)
    rc, out = verilator(board, config, "quux", "--json-only", mdir, word_bits=bits)
    if rc != 0:
        say(False, "%s --- the JSON dump failed:\n%s" % (what, out.strip()))
        return
    with open(os.path.join(mdir, "V%s.tree.json" % top)) as f:
        tree = json.load(f)
    shutil.rmtree(mdir, True)
    got, why = word_bits_at_instance(tree, top)
    if got is None:
        say(False, "%s --- %s" % (what, why))
    elif got != want:
        say(False, "%s --- it elaborates %d" % (what, got))
    else:
        say(True, what)
    # **AND THE REVISION'S K**: on the Arty revision 13's is not revision 12's.
    k_at_generator(board, config, "MACHINE=quux, %s" % asked, want, tree)
    # And no debug cable at revision 13 either.
    cable_at_top(board, config, "MACHINE=quux, %s" % asked, "quux", tree)
    # And the console's memory boards are the revision's.
    boards_at_console(board, config, "MACHINE=quux, %s" % asked, want > 32, tree)
    if board == "kr260":
        kr260_raster(config, "MACHINE=quux, %s" % asked, "quux", tree)
    # And the file device's page names the revision: "QF13" at 40 bits,
    # "QFD9" below (`rtl/plumbing/quux_fd_face.sv`).
    ident_want = 0x51463133 if want > 32 else 0x51464439
    what = "%s, %s, MACHINE=quux, %s: u_fd_face's IDENT is %08x" % (top, config, asked, ident_want)
    got, why = fd_ident_at_instance(tree, top)
    if got is None:
        say(False, "%s --- %s" % (what, why))
    elif got != ident_want:
        say(False, "%s --- it is %08x" % (what, got))
    else:
        say(True, what)


def sync_k_at_generator(tree):
    """The SYNC_K of the one `quux_phase_gen` the tree elaborates."""
    mods = []
    walk(tree, lambda n: mods.append(n)
         if n.get("type") == "MODULE" and n.get("origName") == "quux_phase_gen" else None)
    if len(mods) != 1:
        return None, "%d quux_phase_gen modules in the tree" % len(mods)
    values = []

    def param(n):
        if n.get("type") == "VAR" and n.get("name") == "SYNC_K" and n.get("isParam"):
            v = n.get("valuep") or []
            values.append(v[0]["name"] if len(v) == 1 and v[0].get("type") == "CONST" else None)
    walk(mods[0], param)
    if len(values) != 1 or values[0] is None:
        return None, "no constant SYNC_K in quux_phase_gen"
    # Verilator writes a constant as 32'h4 or 32'sh4.
    return int(values[0].split("h")[-1], 16), None


def reaches(board, config, value, scratch):
    """The value asked for lints clean and is the value at u_machine."""
    top = BOARDS[board]["top"]
    want = value if value is not None else "cadr"
    asked = "MACHINE=%s" % value if value is not None else "no MACHINE"
    what = "%s, %s, %s: u_machine elaborates MACHINE \"%s\"" % (top, config, asked, want)
    rc, out = verilator(board, config, value, "--lint-only")
    if rc != 0:
        say(False, "%s --- the lint failed:\n%s" % (what, out.strip()))
        return
    mdir = tempfile.mkdtemp(dir=scratch)
    rc, out = verilator(board, config, value, "--json-only", mdir)
    if rc != 0:
        say(False, "%s --- the JSON dump failed:\n%s" % (what, out.strip()))
        return
    with open(os.path.join(mdir, "V%s.tree.json" % top)) as f:
        tree = json.load(f)
    shutil.rmtree(mdir, True)
    got, why = machine_at_instance(tree, top)
    if got is None:
        say(False, "%s --- %s" % (what, why))
    elif got != want:
        say(False, "%s --- it elaborates \"%s\"" % (what, got))
    else:
        say(True, what)
    # **AND THE DEBUG CABLE IS THERE ON THE CADR AND NOWHERE ON QUUX.**
    cable_at_top(board, config, asked, want, tree)
    # **AND THE CONSOLE'S MEMORY BOARDS ARE THE CADR'S AND REVISION 12'S.**
    boards_at_console(board, config, asked, False, tree)
    # **AND QUUX'S K REACHES ITS GENERATOR**: the board's own SYNC_K, through
    # `cadr_machine` and `cadr_microcycle`, is the K `quux_phase_gen` counts.
    # A top level that dropped it would build the machine at the default K
    # and every trace at that K would still pass.
    if want == "quux":
        k_at_generator(board, config, "MACHINE=quux", 32, tree)
    if board == "kr260":
        kr260_raster(config, asked, want, tree)


def kr260_raster(config, asked, machine, tree):
    """**THE KRIA KR260'S DISPLAY IS BUILT AT THE RASTER ITS CHECK HOLDS.**
    `build/display_out_kr260.pass` builds `cadr_display_out` with the figures
    in `boards/kria-kr260/display_raster.mk` and holds the eight edges at them;
    this holds that the board's top level hands its `u_display` the same
    figures, read at the instance, and the machine's own picture."""
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
    what = "%s, %s, %s: u_display's raster is display_raster.mk's" % (top, config, asked)
    if sorted(want) != sorted(raster):
        say(False, "%s --- display_raster.mk names %s" % (what, sorted(want)))
        return
    pic = {"PIC_W": 768, "PIC_H": 963, "WORDS_PER_LINE": 24, "SPREAD": 1} if machine == "cadr" \
        else {"PIC_W": 1280, "PIC_H": 1024, "WORDS_PER_LINE": 40, "SPREAD": 0}
    want.update(pic)
    got, why = params_at_cell(tree, top, "u_display", list(want))
    if got is None:
        say(False, "%s --- %s" % (what, why or "no u_display"))
    elif got != want:
        say(False, "%s --- it elaborates %s, want %s" % (
            what, ", ".join("%s=%d" % kv for kv in sorted(got.items())),
            ", ".join("%s=%d" % kv for kv in sorted(want.items()))))
    else:
        say(True, "%s, and %s's picture %dx%d" % (what, machine, pic["PIC_W"], pic["PIC_H"]))


def k_at_generator(board, config, asked, bits, tree):
    """The K `quux_phase_gen` counts is the board's own for the word."""
    top = BOARDS[board]["top"]
    k_want = BOARDS[board]["sync_k"][bits]
    kwhat = "%s, %s, %s: the microcycle is SYNC_K=%d ticks at the generator" % (
        top, config, asked, k_want)
    k, why = sync_k_at_generator(tree)
    if k is None:
        say(False, "%s --- %s" % (kwhat, why))
    elif k != k_want:
        say(False, "%s --- it counts %d" % (kwhat, k))
    else:
        say(True, kwhat)


def refused_at(board, config, value, message, instance):
    """Elaboration stops with `message`, noted in `instance`."""
    top = BOARDS[board]["top"]
    what = "%s, %s, MACHINE=%s: refused in %s" % (top, config, value, instance)
    rc, out = verilator(board, config, value, "--lint-only")
    lines = out.split("\n")
    at = [i for i, line in enumerate(lines) if message in line]
    noted = any("In instance '%s'" % instance in line
                for i in at for line in lines[i + 1:i + 3])
    if rc == 0:
        say(False, "%s --- the lint passed" % what)
    elif not at:
        say(False, "%s --- no line says \"%s\":\n%s" % (what, message, out.strip()))
    elif not noted:
        say(False, "%s --- the refusal is not noted in that instance:\n%s"
            % (what, out.strip()))
    else:
        say(True, what)


def flow(what, cmd, env_add, rc_want, has, lacks):
    env = dict(os.environ)
    env.pop("MACHINE", None)
    env.pop("WORD_BITS", None)
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


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: machine_param_check.py <repository root>")
    os.chdir(sys.argv[1])
    os.makedirs("build", exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="machine_param.", dir="build")
    try:
        for board, spec in sorted(BOARDS.items()):
            for config in spec["configs"]:
                for value in [None] + spec["machines"]:
                    reaches(board, config, value, scratch)
        for board in ("arty", "de25"):
            top = BOARDS[board]["top"]
            refused_at(board, "plain", NOT_A_MACHINE,
                       'cadr_machine: MACHINE is "%s"' % NOT_A_MACHINE,
                       "%s.u_machine" % top)
        for config in BOARDS["cora"]["configs"]:
            refused_at("cora", config, "quux",
                       "the Cora Z7-07S builds the CADR only", "cadr_cora")
        # QUUX at revision 12's word is refused on the Kria KR260, which
        # builds revision 13 alone.
        for config in BOARDS["kr260"]["configs"]:
            refused_at("kr260", config, "quux",
                       "and the Kria KR260 builds the CADR and QUUX revision 13", "cadr_kr260")
        # The word, on the boards that build QUUX.
        for board in ("arty", "de25"):
            for bits in (None, 40):
                word_reaches(board, "DDR=1 HDMI=1", bits, scratch)
        # With the processing system: the file device's page is there only
        # behind its port, as on the other boards.
        word_reaches("kr260", "DDR=1", 40, scratch)

        # **THE ARTY'S FLOW STATES THE K ITS MACHINE COUNTS**: `tick.tcl`'s
        # `cadr_sync_k` for each word is the table's, and the flow sets the
        # `sync_k` that `quux_machine.xdc` writes its counts from with it,
        # for the word it builds, before it reads that file.
        for bits in (32, 40):
            k_want = BOARDS["arty"]["sync_k"][bits]
            what = "the Arty's flow states K=%d at WORD_BITS=%d (tick.tcl, cadr_sync_k)" % (k_want, bits)
            script = os.path.join(scratch, "sync_k.tcl")
            with open(script, "w") as f:
                f.write("source boards/arty-z7-20/vivado/tick.tcl\nputs \"K=[cadr_sync_k %d]\"\n" % bits)
            rc, out = run([TCLSH, script])
            if rc != 0 or ("K=%d" % k_want) not in out.split("\n"):
                say(False, "%s --- it says:\n%s" % (what, out.strip()))
            else:
                say(True, what)
        with open("boards/arty-z7-20/vivado/bitstream.tcl") as f:
            text = f.read()
        sets = [i for i, line in enumerate(text.split("\n"))
                if line.strip() == "set sync_k [cadr_sync_k $word_bits]"]
        reads = [i for i, line in enumerate(text.split("\n"))
                 if "read_xdc" in line and "quux_machine.xdc" in line and not line.lstrip().startswith("#")]
        what = "the Arty's flow sets sync_k from the word it builds, once, before quux_machine.xdc"
        if len(sets) != 1 or len(reads) != 1 or sets[0] > reads[0]:
            say(False, "%s --- %d such line(s), %d read(s) of the file" % (what, len(sets), len(reads)))
        else:
            say(True, what)

        # The flows.  Every OUTDIR is under the scratch directory, so a flow
        # that failed to refuse writes nothing anywhere else.
        arty = [TCLSH, "boards/arty-z7-20/vivado/bitstream.tcl"]
        cora = [TCLSH, "boards/cora-z7-07s/vivado/bitstream.tcl"]
        kr260 = [TCLSH, "boards/kria-kr260/vivado/bitstream.tcl"]
        out = lambda name: os.path.join(scratch, name)
        flow("the Arty's Vivado flow refuses MACHINE=%s" % NOT_A_MACHINE, arty,
             {"MACHINE": NOT_A_MACHINE, "OUTDIR": out("a")}, 1,
             ["BIT: FAILED --- MACHINE=%s is not a machine" % NOT_A_MACHINE],
             ["BIT: the machine is"])
        flow("the Arty's Vivado flow refuses MACHINE=quux into a directory not named for it",
             arty, {"MACHINE": "quux", "OUTDIR": out("ddr")}, 1,
             ["BIT: FAILED --- MACHINE=quux into OUTDIR="],
             ["BIT: the machine is"])
        for value in ("cadr", "quux"):
            flow("the Arty's Vivado flow takes MACHINE=%s" % value, arty,
                 {"MACHINE": value, "OUTDIR": out("arty-%s-ddr" % value)}, None,
                 ["BIT: the machine is %s" % value], ["FAILED --- MACHINE"])
        flow("the Arty's Vivado flow takes no MACHINE as cadr", arty,
             {"OUTDIR": out("b")}, None,
             ["BIT: the machine is cadr"], ["FAILED --- MACHINE"])
        flow("the Arty's Vivado flow refuses WORD_BITS=36", arty,
             {"MACHINE": "quux", "WORD_BITS": "36", "OUTDIR": out("arty-quux13-ddr")}, 1,
             ["BIT: FAILED --- WORD_BITS=36 is not a word"], ["BIT: the machine is"])
        flow("the Arty's Vivado flow refuses WORD_BITS=40 on the CADR", arty,
             {"MACHINE": "cadr", "WORD_BITS": "40", "OUTDIR": out("e")}, 1,
             ["BIT: FAILED --- WORD_BITS=40 is QUUX revision 13, and MACHINE=cadr"],
             ["BIT: the machine is"])
        flow("the Arty's Vivado flow refuses revision 13 into a directory not named for it",
             arty, {"MACHINE": "quux", "WORD_BITS": "40", "OUTDIR": out("arty-quux-ddr")}, 1,
             ["BIT: FAILED --- WORD_BITS=40 into OUTDIR="], ["BIT: the machine is"])
        flow("the Arty's Vivado flow refuses revision 12 into a directory named for 13",
             arty, {"MACHINE": "quux", "OUTDIR": out("arty-quux13-ddr")}, 1,
             ["BIT: FAILED --- WORD_BITS=32 into OUTDIR="], ["BIT: the machine is"])
        flow("the Arty's Vivado flow takes WORD_BITS=40 on QUUX", arty,
             {"MACHINE": "quux", "WORD_BITS": "40", "OUTDIR": out("arty-quux13-ddr")}, None,
             ["BIT: the machine is quux, revision 13 (WORD_BITS=40)"], ["FAILED --- WORD_BITS"])
        # **EACH REVISION'S BOOT PROM IS ITS OWN** (contract G2 §2.8): the
        # Arty's flow names the image it builds in, and a revision given the
        # other's never boots its band.
        proms = {("cadr", None): "build/boot_prom.hex",
                 ("quux", None): "build/boot_prom.quux.hex",
                 ("quux", "40"): "build/boot_prom.quux13.hex"}
        for (value, bits), image in sorted(proms.items(), key=str):
            env_add = {"MACHINE": value,
                       "OUTDIR": out("arty-%s%s-ddr" % (value, "13" if bits else ""))}
            if bits:
                env_add["WORD_BITS"] = bits
            flow("the Arty's Vivado flow builds MACHINE=%s%s with %s"
                 % (value, " WORD_BITS=%s" % bits if bits else "", image), arty, env_add, None,
                 ["BIT: the boot PROM is %s\n" % image],
                 ["BIT: the boot PROM is %s\n" % other for other in proms.values() if other != image])
        flow("the Cora's Vivado flow refuses MACHINE=quux", cora,
             {"MACHINE": "quux", "OUTDIR": out("c")}, 1,
             ["BIT: FAILED --- MACHINE=quux, and the Cora Z7-07S builds the"], [])
        flow("the Cora's Vivado flow takes MACHINE=cadr", cora,
             {"MACHINE": "cadr", "OUTDIR": out("d")}, None,
             [], ["FAILED --- MACHINE"])
        flow("the Kria KR260's Vivado flow refuses MACHINE=quux at revision 12's word", kr260,
             {"MACHINE": "quux", "OUTDIR": out("k-quux13")}, 1,
             ["BIT: FAILED --- MACHINE=quux at WORD_BITS=32, and the Kria KR260 builds"],
             ["BIT: the machine is"])
        flow("the Kria KR260's Vivado flow refuses MACHINE=%s" % NOT_A_MACHINE, kr260,
             {"MACHINE": NOT_A_MACHINE, "OUTDIR": out("k2")}, 1,
             ["BIT: FAILED --- MACHINE=%s is not a machine" % NOT_A_MACHINE], ["BIT: the machine is"])
        flow("the Kria KR260's Vivado flow refuses WORD_BITS=40 on the CADR", kr260,
             {"MACHINE": "cadr", "WORD_BITS": "40", "OUTDIR": out("k3")}, 1,
             ["BIT: FAILED --- WORD_BITS=40 is QUUX revision 13, and MACHINE=cadr"],
             ["BIT: the machine is"])
        flow("the Kria KR260's Vivado flow refuses revision 13 into a directory not named for it",
             kr260, {"MACHINE": "quux", "WORD_BITS": "40", "OUTDIR": out("k-quux")}, 1,
             ["BIT: FAILED --- MACHINE=quux into OUTDIR="], ["BIT: the machine is"])
        flow("the Kria KR260's Vivado flow takes WORD_BITS=40 on QUUX with PROM 2001", kr260,
             {"MACHINE": "quux", "WORD_BITS": "40", "OUTDIR": out("kr260-quux13")}, None,
             ["BIT: the machine is quux, revision 13 (WORD_BITS=40)\n",
              "BIT: the boot PROM is build/boot_prom.quux13.hex\n"],
             ["FAILED --- MACHINE", "FAILED --- WORD_BITS"])
        flow("the Kria KR260's Vivado flow takes MACHINE=cadr with MIT's PROM", kr260,
             {"MACHINE": "cadr", "OUTDIR": out("l")}, None,
             ["BIT: the machine is cadr\n", "BIT: the boot PROM is build/boot_prom.hex\n"],
             ["FAILED --- MACHINE"])

        nowhere = {"QUARTUS_ROOTDIR": out("no-quartus")}
        for script, who in (("build.sh", "de25"), ("program.sh", "de25-program")):
            cmd = ["sh", "boards/de25-nano/quartus/" + script, "x"]
            flow("the DE25-Nano's %s refuses MACHINE=%s" % (script, NOT_A_MACHINE),
                 cmd, dict(nowhere, MACHINE=NOT_A_MACHINE), 1,
                 ["%s: REFUSED: MACHINE is '%s'" % (who, NOT_A_MACHINE)], [])
            for value in ("cadr", "quux"):
                # Accepted, and refused only later for the Quartus that is
                # not there.
                flow("the DE25-Nano's %s takes MACHINE=%s" % (script, value),
                     cmd, dict(nowhere, MACHINE=value), 1,
                     ["%s: REFUSED:" % who], ["REFUSED: MACHINE is"])
        for script, who in (("build.sh", "de25"), ("program.sh", "de25-program")):
            cmd = ["sh", "boards/de25-nano/quartus/" + script, "x"]
            flow("the DE25-Nano's %s refuses WORD_BITS=36" % script, cmd,
                 dict(nowhere, MACHINE="quux", WORD_BITS="36"), 1,
                 ["%s: REFUSED: WORD_BITS is '36'" % who], [])
            flow("the DE25-Nano's %s refuses WORD_BITS=40 on the CADR" % script, cmd,
                 dict(nowhere, MACHINE="cadr", WORD_BITS="40"), 1,
                 ["%s: REFUSED: WORD_BITS=40 is QUUX revision 13, and MACHINE=cadr" % who], [])
            flow("the DE25-Nano's %s takes WORD_BITS=40 on QUUX" % script, cmd,
                 dict(nowhere, MACHINE="quux", WORD_BITS="40"), 1,
                 ["%s: REFUSED:" % who], ["REFUSED: WORD_BITS"])
        # A fault build carries no machine, so QUUX beside it is refused, and
        # the CADR, the default, is taken as far as the missing Quartus.
        cmd = ["sh", "boards/de25-nano/quartus/build.sh", "x"]
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
    print("machine: every board's top level hands MACHINE, WORD_BITS and its K to u_machine, "
          "and the Cora and the flows refuse what they must")
    return 0


if __name__ == "__main__":
    sys.exit(main())
