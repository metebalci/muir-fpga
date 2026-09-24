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


def verilator(board, config, value, mode, mdir=None):
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

        # The flows.  Every OUTDIR is under the scratch directory, so a flow
        # that failed to refuse writes nothing anywhere else.
        arty = [TCLSH, "boards/arty-z7-20/vivado/bitstream.tcl"]
        cora = [TCLSH, "boards/cora-z7-07s/vivado/bitstream.tcl"]
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
        flow("the Cora's Vivado flow refuses MACHINE=quux", cora,
             {"MACHINE": "quux", "OUTDIR": out("c")}, 1,
             ["BIT: FAILED --- MACHINE=quux, and the Cora Z7-07S builds the"], [])
        flow("the Cora's Vivado flow takes MACHINE=cadr", cora,
             {"MACHINE": "cadr", "OUTDIR": out("d")}, None,
             [], ["FAILED --- MACHINE"])

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
    print("machine: every board's top level hands MACHINE to u_machine, "
          "and the Cora and the flows refuse what they must")
    return 0


if __name__ == "__main__":
    sys.exit(main())
