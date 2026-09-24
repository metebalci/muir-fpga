#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""MIT's grid has more than one home, and the homes must agree.

`rtl/machine/cadr_tick_pkg.sv` is the grid for the fabric, `tb/cadr_tick.h`
for the testbenches, and every generator under `golden/src/` that turns a
nanosecond into a tick carries its own `TICK_NS`, being a separate binary with
no shared library.  The checkpoint writer on the board carries `CHK_GRID_NS`,
and the console's host model counts a microcycle in ticks.  A grid that differs between them does not fail to build.
It compares a correct design against the wrong instant, which is the failure
this project is least able to see, so this check says it out loud.

It fails when a home cannot be found as well as when two disagree: a pattern
that silently stopped matching would otherwise pass with nothing compared.

**AND THE TIMING CONSTRAINTS THAT WRITE A GRID-DERIVED COUNT AS A LITERAL.**
An XDC is a restricted Tcl and cannot compute `ticks(75)`, so the relaxed set's
count, the bus's setup and the register strobe are numbers typed into
`set_multicycle_path` and into the flows' `assert_multicycle_applied` and
`assert_instance_timing`.  Every such statement under `rtl/` and `boards/` must
carry a tag in the comment block directly above it --- `# grid: <ns> ns` for a
count of MIT's instants, or `# board ticks` for a fabric choice such as the
debug link's beat --- and a grid-tagged count must be `ticks(ns)` at the
package's grid, its hold one less.  A statement with no tag fails, so a new
literal cannot arrive unaccounted for.

**AND THE MODEL EVERY GENERATOR RUNS muir UNDER.**  muir keeps the board's
own nanoseconds unless it is told the fabric's grid (`TimingModel::Fpga`), so a
generator that builds `Rtl`, `Busint`, `IoBoardTiming` or the disk's
`Controller` on the board's time writes a reference for a machine at no grid
this fabric keeps.  It fails here naming the file.

**AND A COUNT ONE TICK EITHER SIDE OF AN INSTANT.**  The processor's
registers move one tick after the generator's boundary, where the scratchpad
latches close at the read tap itself and the control store is written a tick
after it, so some deadlines are an instant's count and one tick more or less:
the IR to the latch at the fast read tap is `ticks(75) - 1`.  Such a count is
tagged `# grid: 75 ns - 1 tick` or `# grid: 60 ns + 1 tick`, and held to that.
The tick is the fabric's and not MIT's, which is why it is written out rather
than folded into a nanosecond figure no drawing has.

**A COUNT TWO INSTANTS SHARE.**  Two instants of different nanoseconds can come
to one count at a coarse grid --- 75 and 80 are both eight ticks at 10 ns ---
and a requirement cannot say which clause gave it.  An
`assert_multicycle_applied` whose count another grid-tagged constraint shares
must say so in its tag, `# grid: 75 ns (shared with 80 ns)`, naming every
instant it shares with; the flows' own comments say what holds each clause
instead.

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
    check_packages(root, fabric)
    check_power_on(root)

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
    check_timing_model(root)
    constraints = check_constraints(root, fabric)
    print(f"ok: the grid is {fabric} ns in the fabric, the testbenches and "
          f"{count} generator constants in {len(generators)} files, and "
          f"{constraints} constraint counts agree with it")


# The machine's power-on, in edges after the reset edge: one number in the
# package, the testbenches' copy of it, and no module keeping a literal of its
# own.  A module that started its clocks at a count of its own would agree
# with its own check and not with the whole machine, which is issue #21.
POWER_ON_USERS = ["rtl/machine/cadr_busint_xbus.sv", "rtl/machine/cadr_io_board.sv",
                  "rtl/machine/cadr_tv.sv"]


def check_power_on(root):
    fabric = one(root / "rtl/machine/cadr_tick_pkg.sv",
                 r"^\s*localparam\s+int\s+unsigned\s+POWER_ON_EDGES\s*=\s*(\d+)\s*;",
                 "the package's POWER_ON_EDGES")
    bench = one(root / "tb/cadr_tick.h",
                r"^\s*constexpr\s+int\s+kPowerOnEdges\s*=\s*(\d+)\s*;",
                "the testbenches' kPowerOnEdges")
    if bench != fabric:
        fail(f"tb/cadr_tick.h says power-on is {bench} edges after the reset edge "
             f"and rtl/machine/cadr_tick_pkg.sv says {fabric}")
    for rel in POWER_ON_USERS:
        text = re.sub(r"//.*", "", (root / rel).read_text())
        if "cadr_tick_pkg::POWER_ON_EDGES" not in text:
            fail(f"{rel} starts its clocks at no `cadr_tick_pkg::POWER_ON_EDGES`")
        if re.search(r"POWER_ON\w*\s*=\s*\d", text):
            fail(f"{rel} writes a power-on count of its own")
    for cpp in sorted((root / "tb").glob("*.cpp")):
        if re.search(r"kPowerOnEdges\s*=", cpp.read_text()):
            fail(f"tb/{cpp.name} keeps a kPowerOnEdges of its own; "
                 f"tb/cadr_tick.h has the one")


# The Linux programs that turn a fabric tick into muir's time, or model the
# machine's cycle in ticks.  The checkpoint writer multiplies the fabric's tick
# count by the grid to get muir's nanoseconds, so it is a home of the grid; the
# console's host model counts a normal microcycle and a diagnostic cycle in
# ticks, which are the grid's counts of 85 + 60 ns and of 260 ns.
PACKAGES = "boards/arty-z7-20/linux/buildroot/package"


def check_packages(root, grid):
    chk = one(root / PACKAGES / "cadr-checkpoint/src/chk.h",
              r"^\s*#define\s+CHK_GRID_NS\s+(\d+)u\s*$",
              "the checkpoint writer's CHK_GRID_NS")
    if chk != grid:
        fail(f"{PACKAGES}/cadr-checkpoint/src/chk.h says the grid is {chk} ns "
             f"and rtl/machine/cadr_tick_pkg.sv says {grid} ns")
    model = root / PACKAGES / "cadr-console/src/console_test.c"
    for name, want, why in (
            ("TICKS_PER_MICROCYCLE", ticks(85, grid) + ticks(60, grid),
             "the normal read tap and the restart, 85 + 60 ns"),
            ("TICKS_PER_DIAGNOSTIC", ticks(260, grid),
             "the diagnostic cycle and its drop, 260 ns")):
        got = one(model, rf"^\s*#define\s+{name}\s+(\d+)u\s*$", name)
        if got != want:
            fail(f"{model.relative_to(root)}: {name} is {got}, and {why} "
                 f"is {want} ticks at the {grid} ns grid")


# muir keeps the board's own nanoseconds unless it is told the fabric's grid,
# and a generator that builds one of these without saying so writes a
# reference for a machine at a grid nobody builds.  Each constructor either
# takes the model or is followed by `set_timing_model` in the same file.
UNTIMED = [
    ("Busint::new(", "Busint::with_timing_model"),
    ("IoBoardTiming::default(", "IoBoardTiming::with_timing_model"),
]
NEEDS_SETTING = ["Rtl::new(", "Controller::default("]


def check_timing_model(root):
    for rs in sorted((root / "golden/src").glob("*.rs")):
        text = rs.read_text()
        for bad, good in UNTIMED:
            if bad in text:
                fail(f"golden/src/{rs.name} builds `{bad}...)` on the board's own time; "
                     f"a reference for the fabric is `{good}(..., TimingModel::Fpga)`")
        for ctor in NEEDS_SETTING:
            if ctor in text and "set_timing_model(" not in text:
                fail(f"golden/src/{rs.name} builds `{ctor}...)` and never calls "
                     f"`set_timing_model`, so it runs on the board's own time")
        if ("set_timing_model(" in text or "with_timing_model(" in text) \
                and "TimingModel::Fpga" not in text:
            fail(f"golden/src/{rs.name} chooses a timing model and it is not "
                 f"`TimingModel::Fpga`, the grid the fabric keeps")


# A statement that writes a count of ticks: a multicycle's setup or hold, or
# one of the flows' two assertions, possibly inside a one-line `if`.
STATEMENT = re.compile(
    r"^\s*(?:if\s*\{[^}]*\}\s*\{\s*)?"
    r"(?:set_multicycle_path\s+-(setup|hold)\s+(\d+)"
    r"|(assert_multicycle_applied|assert_instance_timing|assert_clause_timing)\s+\$tick\s+(\d+))")
TAG = re.compile(
    r"^\s*#\s*(?:grid:\s*(\d+)\s*ns(?:\s*([+-])\s*1\s*tick)?"
    r"(?:\s*\(shared with\s+([\d\s,and]+?)\s*ns\))?"
    r"|(board ticks))\s*$")


def ticks(ns, grid):
    return (ns + grid - 1) // grid


def tag_above(lines, i):
    """The tags in the comment block directly above line `i`, skipping the
    code between them: the other statements of a group, an `if` opener, and
    the object query a constraint names, however many lines it takes."""
    j = i - 1
    while j >= 0 and lines[j].strip() and not lines[j].lstrip().startswith("#"):
        j -= 1
    tags = []
    while j >= 0 and lines[j].lstrip().startswith("#"):
        m = TAG.match(lines[j])
        if m:
            tags.append(m)
        j -= 1
    return tags


def check_constraints(root, grid):
    files = []
    for top in ("rtl", "boards"):
        files += list((root / top).rglob("*.xdc")) + list((root / top).rglob("*.sdc")) \
            + list((root / top).rglob("*.tcl"))
    found = []
    for path in sorted(files):
        lines = path.read_text().splitlines()
        for i, line in enumerate(lines):
            m = STATEMENT.match(line)
            if not m:
                continue
            where = f"{path.relative_to(root)}:{i + 1}"
            tags = tag_above(lines, i)
            if len(tags) != 1:
                fail(f"{where}: `{line.strip()}` needs exactly one `# grid: <ns> ns` or "
                     f"`# board ticks` tag in the comment block above it, and has {len(tags)}")
            t = tags[0]
            kind = m.group(1) or m.group(3)
            count = int(m.group(2) or m.group(4))
            if t.group(4):
                found.append((where, kind, None, count, []))
                continue
            ns = int(t.group(1))
            off = {"+": 1, "-": -1, None: 0}[t.group(2)]
            want = ticks(ns, grid) + off
            said = f"{ns} ns" + (f" {t.group(2)} 1 tick" if off else "")
            if kind == "hold":
                if count != want - 1:
                    fail(f"{where}: a hold of {count} beside {said}, which is {want} ticks at "
                         f"the {grid} ns grid: the hold is one less, {want - 1}")
            elif count != want:
                fail(f"{where}: {count} ticks for {said}, which is {want} at the {grid} ns "
                     f"grid of rtl/machine/cadr_tick_pkg.sv")
            shared = sorted({int(x) for x in re.findall(r"\d+", t.group(3) or "")})
            # An instant a tick either side is its own instant: it shares a
            # count with nothing by virtue of its nanoseconds.
            found.append((where, kind, ns if not off else said, count, shared))
    grid_tagged = [f for f in found if f[2] is not None]
    if not grid_tagged:
        fail("no timing constraint under rtl/ or boards/ carries a `# grid:` tag, "
             "so there is nothing to hold to the grid")
    constrained = {(ns, count) for (_, kind, ns, count, _) in grid_tagged if kind == "setup"}
    for where, kind, ns, count, shared in grid_tagged:
        if kind != "assert_multicycle_applied":
            continue
        others = sorted({o for (o, c) in constrained if c == count and o != ns}, key=str)
        if others != shared:
            fail(f"{where}: `assert_multicycle_applied` for {ns} ns counts {count} ticks, which "
                 f"the constraints for {others or 'no other instant'} ns share; its tag must "
                 f"say `(shared with ...)` for exactly those, and says {shared or 'nothing'}")
    return len(found)


if __name__ == "__main__":
    main()
