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
than folded into a nanosecond figure no drawing has.  A count the fabric
places by ticks alone, such as the map's and the dispatch memory's writes
around a hung microcycle, is tagged `# grid: 0 ns + 3 ticks`, the offset being
any number of ticks.

**A COUNT TWO INSTANTS SHARE.**  Two instants of different nanoseconds can come
to one count at a coarse grid --- 75 and 80 are both eight ticks at 10 ns ---
and a requirement cannot say which clause gave it.  An
`assert_multicycle_applied` whose count another grid-tagged constraint shares
must say so in its tag, `# grid: 75 ns (shared with 80 ns)`, naming every
instant it shares with; the flows' own comments say what holds each clause
instead.

**AND THE NAMES THE CONSTRAINTS WRITE, AGAINST THE REGISTERS THE MACHINE
HAS.**  The relaxed set is every register of the machine less a list of
names, and neither tool warns when a name in that list matches nothing: a
register that is renamed falls back into the set in silence, and its paths
get the fast read tap's eight ticks where the machine gives them one.  That
happened to REQTIM's oscillator, `vco_count` renamed `vco_acc`, and to the
color TV, a second instance of the display board that `*memory/tv/*` does not
reach.  So Verilator elaborates `cadr_machine` for each machine and this
reads the registers out of its tree --- every variable a nonblocking
assignment writes, named as Vivado and Quartus name it --- and holds the
constraints to them two ways:

  - every register pattern in `cadr_machine.xdc`'s and `quux_machine.xdc`'s
    `filter [all_registers]` sets and `get_pins -quiet` lists, and every
    `get_registers` and `get_pins` pattern of `cadr_de25.sdc` and
    `quux_de25.sdc`, must match a register of one machine or the other (a
    leaf written as `X` and `X[*]` is one name, matched by either);
  - and two instances of one module must be in the relaxed set or out of it
    register by register alike, since what decides it is the register's part
    in the module and not where the module is instantiated.  The Vivado set is
    evaluated from the filter's own text and the Quartus set by running the
    SDC files in `tclsh` with the collection commands stubbed.

**AND REVISION 14'S EVERY-TICK REGISTERS OUT OF BOTH RELAXED SETS.**  The
machines are elaborated three ways, the CADR and QUUX at revisions 13 and
14, and every register of revision 14's memory system is classed in
`REV14_CLASSED` as moving on a tick of its own or as held for the
microcycle.  A `tick` register in either relaxed set fails, and so does a
register of `quux_mmu.sv` or `quux_tlb.sv` that is not classed, so one
added later cannot fall into the set unread.

It does not see the names synthesis gives the block memories (`REF_NAME`,
`get_keepers`), which the flows' own assertions ask of the fitted design.

Usage: grid_check.py [ROOT]    (ROOT defaults to the current directory)
"""

import collections
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile


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
    names, regs = check_names(root)
    print(f"ok: the grid is {fabric} ns in the fabric, the testbenches and "
          f"{count} generator constants in {len(generators)} files, and "
          f"{constraints} constraint counts agree with it; {names} register "
          f"names in the constraints each match some of the machines' "
          f"{regs} registers, and no module's instances are split by the "
          f"relaxed set")


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


SYNC_BUILDER = "machine_axis.rs"


def check_timing_model(root):
    # **QUUX'S SYNCHRONOUS MICROCYCLE, AND ONLY QUUX'S.**  `TimingModel::Sync`
    # is built in one place, `machine_axis::take_timing`, in its QUUX arm, so
    # that no CADR trace can be taken on it.  A `Sync { cycle_ticks: ...}`
    # built anywhere else, or in that file outside the arm, fails.
    for rs in sorted((root / "golden/src").glob("*.rs")):
        text = rs.read_text()
        for m in re.finditer(r"TimingModel::Sync\s*\{\s*cycle_ticks\s*:", text):
            if rs.name != SYNC_BUILDER:
                fail(f"golden/src/{rs.name} builds `TimingModel::Sync`; only "
                     f"`{SYNC_BUILDER}`'s QUUX arm may")
            before = text[:m.start()]
            if before.rfind("Which::Quux =>") < before.rfind("Which::Cadr =>"):
                fail(f"golden/src/{rs.name} builds `TimingModel::Sync` outside its QUUX arm")
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
# A count is a number, or, in the Arty's files, K written from the flow's
# `sync_k`: `$sync_k` or `[expr {$sync_k - n}]` (`SYNC_EXPR`).
COUNT = r"(\d+|\$sync_k|\[expr\s*\{\s*\$sync_k\s*[+-]\s*\d+\s*\}\])"
STATEMENT = re.compile(
    r"^\s*(?:if\s*\{[^}]*\}\s*\{\s*)?"
    r"(?:set_multicycle_path\s+-(setup|hold)\s+" + COUNT +
    r"|(assert_multicycle_applied|assert_instance_timing|assert_clause_timing"
    r"|assert_pin_timing|assert_through_timing)\s+\$tick\s+" + COUNT + ")")
SYNC_EXPR = re.compile(r"^\[expr\s*\{\s*\$sync_k\s*([+-])\s*(\d+)\s*\}\]$")
TAG = re.compile(
    r"^\s*#\s*(?:grid:\s*(\d+)\s*ns(?:\s*([+-])\s*(\d+)\s*ticks?)?"
    r"(?:\s*\(shared with\s+([\d\s,and]+?)\s*ns\))?"
    r"|(board ticks)"
    r"|sync:\s*K(?:\s*([+-])\s*(\d+))?)\s*$")

# **QUUX'S MICROCYCLE, K TICKS, IS A BOARD'S AND NOT THE GRID'S** (H1a).  A
# count of QUUX's is tagged `# sync: K`, or `# sync: K - 1` and the like.  On
# the DE25-Nano it is a number, held to the SYNC_K of the board whose
# constraints the file is: the default of that parameter in the board's top
# level, which is what its bitstream is built at.  **ON THE ARTY Z7-20 THE K
# IS THE FLOW'S**, revision 13's five (`SYNC_K13`), so there a count of K is
# never a number: it is written from the flow's `sync_k`
# (`vivado/tick.tcl`), `$sync_k` or `[expr {$sync_k - n}]`, and held here to
# its tag, a hold one tick less; `build/machine_param.pass` holds the flow's
# `sync_k` to the machine.  The Kria KR260's flow builds revision 13 from the same
# `quux_machine.xdc` and reads its K from its own top level (`SYNC_K13`) the
# same way, so its flow's counts are written from `sync_k` too.  A file that
# is no board's may not use the tag.
SYNC_BY_REVISION = ("rtl/plumbing/xilinx7/", "boards/arty-z7-20/", "boards/kria-kr260/")
SYNC_BOARDS = [
    ("boards/de25-nano/", "boards/de25-nano/cadr_de25.sv"),
]


def board_sync_k(root, rel):
    for prefix, top in SYNC_BOARDS:
        if rel.startswith(prefix):
            return one(root / top,
                       r"^\s*parameter\s+int\s+unsigned\s+SYNC_K\s*=\s*(\d+)\s*,?\s*$",
                       "the board's SYNC_K"), top
    return None, None
# A tag's groups: 1 the nanoseconds, 2 and 3 the sign and the number of
# fabric ticks either side of them, 4 the instants it shares a count with,
# 5 `board ticks`.


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
            text = m.group(2) or m.group(4)
            is_sync = t.group(0).split("#", 1)[1].strip().startswith("sync:")
            rel = str(path.relative_to(root))
            if not text.isdigit():
                # K written from `sync_k`: only under a `# sync:` tag, only in
                # the Arty's files, and saying the tag's offset.
                if not is_sync:
                    fail(f"{where}: `{text}` is a count of K under a tag that is not `# sync:`")
                if not rel.startswith(SYNC_BY_REVISION):
                    fail(f"{where}: `{text}` in a file that is not the Arty's, whose K the "
                         f"flow does not set")
                e = SYNC_EXPR.match(text)
                got = 0 if text == "$sync_k" else (int(e.group(2)) if e.group(1) == "+"
                                                   else -int(e.group(2)))
                off = int(t.group(7)) if t.group(6) else 0
                tag_off = off if t.group(6) == "+" else -off
                said = "K" + (f" {t.group(6)} {off}" if t.group(6) else "")
                want = tag_off - 1 if kind == "hold" else tag_off
                if got != want:
                    fail(f"{where}: `{text}` beside {said}: it is K {got:+d}, and wants K "
                         f"{want:+d}" + (", the hold one less" if kind == "hold" else ""))
                found.append((where, kind, None, text, []))
                continue
            count = int(text)
            if is_sync and rel.startswith(SYNC_BY_REVISION):
                fail(f"{where}: {count} ticks for a count of K in the Arty's files, where K is "
                     f"the revision's: write it from `$sync_k`")
            if is_sync:
                k, top = board_sync_k(root, rel)
                if k is None:
                    fail(f"{where}: a `# sync:` count in a file that is no board's, so there "
                         f"is no SYNC_K to hold it to")
                off = int(t.group(7)) if t.group(6) else 0
                want = k + (off if t.group(6) == "+" else -off)
                said = "K" + (f" {t.group(6)} {off}" if t.group(6) else "")
                if kind == "hold":
                    if count != want - 1:
                        fail(f"{where}: a hold of {count} beside {said}, which is {want} ticks "
                             f"at {top}'s SYNC_K of {k}: the hold is one less, {want - 1}")
                elif count != want:
                    fail(f"{where}: {count} ticks for {said}, which is {want} at {top}'s "
                         f"SYNC_K of {k}")
                found.append((where, kind, None, count, []))
                continue
            if t.group(5):
                found.append((where, kind, None, count, []))
                continue
            ns = int(t.group(1))
            ticks_off = int(t.group(3)) if t.group(2) else 0
            off = {"+": ticks_off, "-": -ticks_off, None: 0}[t.group(2)]
            want = ticks(ns, grid) + off
            said = f"{ns} ns" + (f" {t.group(2)} {ticks_off} tick{'s' if ticks_off != 1 else ''}"
                                 if off else "")
            if kind == "hold":
                if count != want - 1:
                    fail(f"{where}: a hold of {count} beside {said}, which is {want} ticks at "
                         f"the {grid} ns grid: the hold is one less, {want - 1}")
            elif count != want:
                fail(f"{where}: {count} ticks for {said}, which is {want} at the {grid} ns "
                     f"grid of rtl/machine/cadr_tick_pkg.sv")
            shared = sorted({int(x) for x in re.findall(r"\d+", t.group(4) or "")})
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


# ------------------------------------------------ the names the constraints write

VERILATOR = os.environ.get("VERILATOR", "verilator")
TCLSH = os.environ.get("TCLSH", "tclsh")
# Each machine as a board builds it: the CADR, QUUX at revision 13, and QUUX at
# revision 14, whose memory system (`quux_mmu.sv`, `quux_tlb.sv`) only that
# revision elaborates.
MACHINES = ("cadr", "quux", "quux14")
GENERICS = {"cadr": ['-GMACHINE="cadr"'],
            "quux": ['-GMACHINE="quux"', "-GWORD_BITS=40"],
            "quux14": ['-GMACHINE="quux"', "-GWORD_BITS=40", "-GREVISION=14"]}
XDC_NAMED = ["rtl/plumbing/xilinx7/cadr_machine.xdc", "rtl/plumbing/xilinx7/quux_machine.xdc",
             "rtl/plumbing/xilinx7/quux14_machine.xdc"]
# The SDC files each machine's build reads, in the order `project.tcl` reads them.
SDC_NAMED = {"cadr": ["boards/de25-nano/quartus/cadr_de25.sdc"],
             "quux": ["boards/de25-nano/quartus/cadr_de25.sdc",
                      "boards/de25-nano/quartus/quux_de25.sdc"],
             "quux14": ["boards/de25-nano/quartus/cadr_de25.sdc",
                        "boards/de25-nano/quartus/quux_de25.sdc"]}

# **REVISION 14'S REGISTERS, EACH CLASSED BY WHEN IT MOVES** (contract G3
# revision 14, F2).  The relaxed set is every register of the machine less a
# list of names, so a register of revision 14 that moves on a tick of its own
# and is left off that list is relaxed in silence: its paths get the
# microcycle where the machine gives them one tick, and nothing in a trace
# can see it.  So every register of the memory system's two modules is
# classed here, read off the RTL, and a register added to either without a
# class fails:
#
#   - `tick`: moves on a tick of its own, or is read by a register that does,
#     and must be out of the relaxed set on both families' boards;
#   - `held`: loaded at an instant the microcycle owns and read only by
#     registers that keep its time, and may be in it.
#
# `quux_mmu.sv`: the generator's ticks (`g1`, `g2`, `since_start`), the hold
# (`held`, `res_mid`), the walk's and the write-back's countdowns (`until_s`,
# `b_t`) and the sweep's (`sweep_s`, `sweeping`, `sweep_i`), the walker's and
# the write-back's machines and what they carry (`wstate`, `w_*`, `wk_*`,
# `spec_*`, `bstate`, `b_*`, `st1`), the walk's results (`ra*`, `rb*`,
# `walked_*`, `redirect_held`), the TLB's pending writes (`pa_*`, `pb_*`),
# the redirect's pending read and its registers for the PDL buffer
# (`rd_pend`, `redirect_in_q`, `redirect_idx_q`) and the guard's count and
# its pulse (`refused`, `refuse_now`) all move on whatever tick the side seam
# answers on, or on every tick.  Held: the register page's words 220-223
# (`directory`, `ephemeral`, `pointer_types`), written at the page's answer
# from a word the bus has held for eight ticks, the redirect's copies
# (`pdl_base`, `pdl_head`), written by A memory's own pulse from `L` as A
# memory is, and the edge's registers (`e_*`), loaded at an edge alone: the
# TLB's forwards and the walk's entries the datapath reads, the writes
# landing at the edge, and the write-back's grant.
# `quux_tlb.sv`'s memory and its two outputs are the TLB's RAM, in the set
# and given their own time by the flows (`quux_machine.xdc`,
# `quux_de25.sdc`).  In `cadr_microcycle.sv`, the redirect's word and its
# strobe (`redir_rd_q`, `redir_word`), taken a tick after the PDL buffer's
# read.  And the memory port and its cache, out whole: every register of
# `quux_mem_port.sv` and `quux_cache.sv` (the walk's countdowns `free_s`,
# `buf_s`, `g_s`, `wbu_s`, `ack_s`, `ack_last_s`, the release `rel_q`,
# `rel_pend` and `rel_ok_q`, the write's `s_wpend`, `s_wr_late_q` and `wbw`,
# and `granted1` among them) out of the set.
REV14 = "quux14"
REV14_TICK = "tick"
REV14_HELD = "held"
REV14_CLASSED = {
    "quux_mmu": {
        **{n: REV14_HELD for n in ("directory", "ephemeral", "pointer_types",
                                   "pdl_base", "pdl_head",
                                   "e_fa_v", "e_fb_v", "e_fa_hit", "e_fb_hit", "e_fa_ent", "e_fb_ent",
                                   "e_bpa_v", "e_bpb_v", "e_bpa", "e_bpb",
                                   "e_or_v", "e_op_v", "e_or_idx", "e_op_idx", "e_or_w", "e_op_w",
                                   "e_go", "e_ref", "e_bits", "e_frame")},
        **{n: REV14_TICK for n in (
            "g1", "g2", "since_start", "held", "res_mid", "until_s", "b_t",
            "sweep_s", "sweeping", "sweep_i",
            "wstate", "w_port", "w_b_queued", "w_va", "w_page_at", "w_first", "w_done",
            "wk_page_v", "wk_page_at", "wk_page", "spec_v", "spec_port",
            "bstate", "b_va", "b_ul", "b_frame", "b_bits", "b_page_at", "b_page", "st1",
            "ra_v", "rb_v", "ra", "rb", "rb_va",
            "walked_a", "walked_b", "redirect_held",
            "pa_v", "pb_v", "pa_idx", "pb_idx", "pa_w", "pb_w",
            "rd_pend", "redirect_in_q", "redirect_idx_q", "refused", "refuse_now",
            "d_wa", "d_wb", "d_redir", "lv_dok", "lv_gok",
            "f_v", "f_word", "f_dok", "f_gok", "f_load", "b_rel_n", "w_ua", "wb_rel_now_q")},
    },
    "quux_tlb": {n: REV14_HELD for n in ("tlb_mem", "a_q", "b_q")},
}
# Registers of modules shared with other revisions, named one by one.
REV14_NAMED_TICK = {
    "cadr_microcycle": ("g_quux_pdl.redir_rd_q", "redir_word"),
    "quux_mem_port": ("free_s", "buf_s", "g_s", "wbu_s", "ack_s", "ack_last_s",
                      "rel_q", "rel_pend", "s_wpend", "s_wr_late_q", "wbw", "granted1", "rel_ok_q"),
}
# Modules out of the relaxed set whole, register by register.
REV14_OUT_WHOLE = ("quux_mem_port", "quux_cache")

# One register of one instance: the module it is in, its name inside the
# module (a generate block's name before it, as both tools write it), and its
# full name as Vivado and as Quartus give it, a vector's bit 0 standing for
# the rest.
Reg = collections.namedtuple("Reg", "module local vivado quartus")


def walk(node, fn):
    if isinstance(node, dict):
        fn(node)
        for v in node.values():
            walk(v, fn)
    elif isinstance(node, list):
        for v in node:
            walk(v, fn)


def elaborate(root, machine, scratch):
    """The registers of `cadr_machine` built as `machine`, QUUX at its 40-bit
    word, out of Verilator's elaborated tree: parameters applied and generate
    blocks chosen, so each machine has exactly the instances its bitstream
    has."""
    mdir = os.path.join(scratch, machine)
    cmd = [VERILATOR, "--json-only", "-Irtl/machine", "-Irtl/plumbing", "-Mdir", mdir,
           *GENERICS[machine],
           "--top-module", "cadr_machine",
           "rtl/machine/cadr_tick_pkg.sv", "rtl/plumbing/cadr_ddr_map.sv",
           "rtl/machine/cadr_machine.sv"]
    p = subprocess.run(cmd, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if p.returncode != 0:
        fail(f"Verilator could not elaborate cadr_machine as {machine}:\n"
             + p.stdout.decode("utf-8", "replace")[-2000:])
    with open(os.path.join(mdir, "Vcadr_machine.tree.json")) as f:
        tree = json.load(f)
    by = {}
    walk(tree, lambda n: by.__setitem__(n["addr"], n) if "addr" in n else None)
    written = set()

    def lhs(n):
        if n.get("type") == "VARREF" and n.get("access") == "WR":
            written.add(n.get("varp"))
    walk(tree, lambda n: walk(n.get("lhsp", []), lhs) if n.get("type") == "ASSIGNDLY" else None)

    def dims(dt):
        # `[0]` for each unpacked dimension and one for a packed vector.
        out = ""
        for _ in range(16):
            if dt is None:
                return out
            t = dt.get("type")
            if t == "UNPACKARRAYDTYPE":
                out += "[0]"
                dt = by.get(dt.get("refDTypep"))
            elif t == "BASICDTYPE":
                r = dt.get("range", "")
                return out + ("[0]" if r and len(set(r.split(":"))) > 1 else "")
            elif t in ("ENUMDTYPE", "REFDTYPE"):
                nxt = by.get(dt.get("refDTypep"))
                if nxt is None or nxt is dt:
                    return out + "[0]"
                dt = nxt
            else:
                return out + "[0]"
        return out

    tops = [n for n in by.values()
            if n.get("type") == "MODULE" and n.get("origName") == "cadr_machine"]
    if len(tops) != 1:
        fail(f"{len(tops)} cadr_machine modules in Verilator's tree for {machine}")
    regs = []

    def writers(mod):
        """For each variable a nonblocking assignment writes, the generate
        scope of the process that writes it.  Vivado names a register by the
        scope of the process that makes it, not of the declaration: a
        variable declared in the module and written in `g_x` is `g_x.v_reg`,
        measured on a three-register design in Vivado 2026.1, and so is
        QUUX's PDL buffer, `g_quux_pdl.pdl_reg_*` (M7e)."""
        out = {}

        def rec(n, gen):
            if isinstance(n, list):
                for v in n:
                    rec(v, gen)
                return
            if not isinstance(n, dict) or n.get("type") == "CELL":
                return
            if n.get("type") == "ASSIGNDLY":
                def lhs(m):
                    if m.get("type") == "VARREF" and m.get("access") == "WR":
                        out.setdefault(m.get("varp"), gen)
                walk(n.get("lhsp", []), lhs)
            if n.get("type") == "BEGIN" and n.get("generate") and n.get("name") \
                    and not n.get("implied") and not n.get("unnamed"):
                gen = gen + n["name"] + "."
            for v in n.values():
                if isinstance(v, (list, dict)):
                    rec(v, gen)
        for v in mod.values():
            if isinstance(v, (list, dict)):
                rec(v, "")
        return out

    def visit(mod, path):
        wgen = writers(mod)

        def rec(n, gen):
            if isinstance(n, list):
                for v in n:
                    rec(v, gen)
                return
            if not isinstance(n, dict):
                return
            t = n.get("type")
            if t == "CELL":
                visit(by[n["modp"]], path + [gen + n["name"]])
                return
            if t == "VAR":
                if n["addr"] in written:
                    d = dims(by.get(n.get("dtypep")))
                    local = gen + n["name"]
                    viv = (gen or wgen.get(n["addr"], "")) + n["name"]
                    regs.append(Reg(mod.get("origName"), local,
                                    "/".join(path + [viv + "_reg" + d]),
                                    "|".join(["u_machine"] + path + [local + d])))
                return
            if t == "BEGIN" and n.get("generate") and n.get("name") \
                    and not n.get("implied") and not n.get("unnamed"):
                gen = gen + n["name"] + "."
            for v in n.values():
                if isinstance(v, (list, dict)):
                    rec(v, gen)
        for v in mod.values():
            if isinstance(v, (list, dict)):
                rec(v, "")

    visit(tops[0], [])
    if not regs:
        fail(f"no register in Verilator's tree of cadr_machine as {machine}")
    return regs


def glob(pat):
    """Both tools' wildcards: `*` any run, `?` one character, brackets literal."""
    return re.compile("".join(".*" if c == "*" else "." if c == "?" else re.escape(c)
                              for c in pat) + r"\Z")


def filter_sets(rel, text):
    """Each `set X [filter [all_registers] {...}]` of an XDC, as its name, and
    its expression's tokens: ("pat", op, pattern, line) for `NAME =~ p` or
    `NAME !~ p`, ("ref", ...) for a `REF_NAME` term, else ("op", tok, None,
    line).  A token this does not know fails, so a new construct cannot
    arrive unread."""
    sets = []
    for m in re.finditer(r"^set\s+(\w+)\s+\[filter\s+\[all_registers\]\s+\{", text, re.M):
        start = m.end()
        depth, i = 1, start
        while depth:
            if i >= len(text):
                fail(f"{rel}: `set {m.group(1)} [filter ...` has no closing brace")
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        expr = text[start:i - 1]
        line0 = text.count("\n", 0, start) + 1
        toks = []
        for t in re.finditer(r"\\\n|&&|\|\||[()]|(REF_NAME|NAME)\s*(=~|!~)\s*([^\s()]+)|(\S+)",
                             expr):
            ln = line0 + expr.count("\n", 0, t.start())
            if t.group(0) == "\\\n":
                continue
            if t.group(4):
                fail(f"{rel}:{ln}: `{t.group(4)}` in the filter of `{m.group(1)}` is "
                     f"nothing this check reads")
            if t.group(1) == "NAME":
                toks.append(("pat", t.group(2), t.group(3), ln))
            elif t.group(1):
                toks.append(("ref", t.group(2), t.group(3), ln))
            else:
                toks.append(("op", t.group(0), None, ln))
        sets.append((m.group(1), toks))
    return sets


def in_filter(toks, name):
    """Whether `name` passes a filter made only of NAME terms."""
    pos = 0

    def atom():
        nonlocal pos
        t = toks[pos]
        pos += 1
        if t[0] == "pat":
            hit = bool(glob(t[2]).match(name))
            return hit if t[1] == "=~" else not hit
        if t[1] != "(":
            fail(f"line {t[3]}: `{t[1]}` where a term belongs in the relaxed set's filter")
        v = either()
        if pos >= len(toks) or toks[pos][1] != ")":
            fail(f"line {t[3]}: an unclosed `(` in the relaxed set's filter")
        pos += 1
        return v

    def both():
        nonlocal pos
        v = atom()
        while pos < len(toks) and toks[pos][1] == "&&":
            pos += 1
            v = atom() and v
        return v

    def either():
        nonlocal pos
        v = both()
        while pos < len(toks) and toks[pos][1] == "||":
            pos += 1
            v = both() or v
        return v

    v = either()
    if pos != len(toks):
        fail(f"line {toks[pos][3]}: the relaxed set's filter does not parse past here")
    return v


# The SDC files run in `tclsh`, every command a timing analyzer has stubbed:
# a query returns the names of the registers its patterns match and logs each
# pattern with the line of the statement it is in and its count; the
# collection commands are list operations; anything else returns nothing.
SDC_HARNESS = r"""
set names {}
set fh [open [lindex $argv 0]]
foreach l [split [read $fh] \n] { if {$l ne ""} { lappend names $l } }
close $fh
proc unknown args { return {} }
proc query {kind strip args} {
    set f [info frame -2]
    set line [expr {[dict exists $f line] ? [dict get $f line] : 0}]
    set file [expr {[dict exists $f file] ? [dict get $f file] : "?"}]
    set out {}
    foreach p [lindex $args end] {
        set q [string map {\\ \\\\ [ \\[ ] \\]} [regsub $strip $p {}]]
        set n 0
        foreach nm $::names { if {[string match $q $nm]} { lappend out $nm; incr n } }
        puts "PAT\t$kind\t$file\t$line\t$n\t$p"
    }
    return [lsort -unique $out]
}
proc get_registers args { return [query registers {^$} {*}$args] }
proc get_pins args { return [query pins {\|d$} {*}$args] }
proc get_keepers args { return {} }
proc add_to_collection {a b} { return [lsort -unique [concat $a $b]] }
proc remove_from_collection {a b} {
    set d [dict create]
    foreach x $b { dict set d $x 1 }
    set out {}
    foreach x $a { if {![dict exists $d $x]} { lappend out $x } }
    return $out
}
proc get_collection_size {c} { return [llength $c] }
foreach f [lrange $argv 1 end] { source $f }
foreach x $slow { puts "SLOW\t$x" }
puts "END"
"""


def stem(pat):
    """A leaf written as `X` and `X[*]` is one name."""
    return pat[:-3] if pat.endswith("[*]") else pat


def check_names(root):
    """Every name the constraints give a register matches one, and the relaxed
    set treats every instance of a module alike."""
    with tempfile.TemporaryDirectory(prefix="grid_names_") as scratch:
        regs = {m: elaborate(root, m, scratch) for m in MACHINES}

        # The Zynq boards'.  Each pattern of each filter, and each pin of each
        # `get_pins -quiet` list, against both machines' registers.
        hits = collections.Counter()
        where = {}
        slow = None
        for rel in XDC_NAMED:
            text = (root / rel).read_text()
            for name, toks in filter_sets(rel, text):
                if rel.endswith("cadr_machine.xdc") and name == "slow":
                    if any(t[0] == "ref" for t in toks):
                        fail(f"{rel}: the relaxed set's filter names a REF_NAME, which "
                             f"this check cannot evaluate")
                    slow = toks
                for t in toks:
                    if t[0] == "pat":
                        key = (rel, "filter", t[2])
                        where.setdefault(key, t[3])
                        r = glob(t[2])
                        hits[key] += sum(1 for m in MACHINES for x in regs[m] if r.match(x.vivado))
            for m in re.finditer(r"\[get_pins\s+-quiet\s+\{([^}]*)\}", text):
                line0 = text.count("\n", 0, m.start()) + 1
                for p in m.group(1).split():
                    key = (rel, "get_pins", p)
                    where.setdefault(key, line0)
                    r = glob(re.sub(r"/[A-Z]+$", "", p))
                    hits[key] += sum(1 for mm in MACHINES for x in regs[mm] if r.match(x.vivado))
        if slow is None:
            fail(f"{XDC_NAMED[0]}: no `set slow [filter [all_registers] {{...}}]`, so "
                 f"there is no relaxed set to hold to the registers")
        xdc_slow = {m: {x.vivado for x in regs[m] if in_filter(slow, x.vivado)}
                    for m in MACHINES}

        # The DE25-Nano's, run.
        sdc_slow = {}
        harness = os.path.join(scratch, "sdc_harness.tcl")
        with open(harness, "w") as f:
            f.write(SDC_HARNESS)
        for m in MACHINES:
            names = os.path.join(scratch, m + ".names")
            with open(names, "w") as f:
                f.write("\n".join(x.quartus for x in regs[m]) + "\n")
            p = subprocess.run([TCLSH, harness, names] + [str(root / s) for s in SDC_NAMED[m]],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            out = p.stdout.decode("utf-8", "replace").splitlines()
            if p.returncode != 0 or not out or out[-1] != "END":
                fail(f"the DE25-Nano's SDC files for {m} did not run through to the end "
                     f"in tclsh:\n" + "\n".join(out[-20:]))
            sdc_slow[m] = set()
            for line in out:
                fields = line.split("\t")
                if fields[0] == "PAT":
                    kind, path, ln, n, pat = fields[1:]
                    # A name under the board's own top level, the debug
                    # cable's, is no register of the machine's; the flow's
                    # own assertion holds it.
                    if not pat.startswith(("u_machine|", "*")):
                        continue
                    rel = os.path.relpath(path, root) if path != "?" else path
                    key = (rel, kind, stem(pat))
                    where.setdefault(key, int(ln))
                    hits[key] += int(n)
                elif fields[0] == "SLOW":
                    sdc_slow[m].add(fields[1])

    dead = sorted((where[k], k) for k, n in hits.items() if n == 0)
    if dead:
        fail("register names in the timing constraints that match no register of "
             "either machine, so what they meant to keep out of (or put into) a set is "
             "not there, in silence:\n" +
             "\n".join(f"  {rel}:{ln}: {kind} `{pat}`" for ln, (rel, kind, pat) in dead))

    for tool, attr, sets in (("cadr_machine.xdc", "vivado", xdc_slow),
                             ("cadr_de25.sdc", "quartus", sdc_slow)):
        for m in MACHINES:
            groups = collections.defaultdict(lambda: {True: [], False: []})
            for x in regs[m]:
                name = getattr(x, attr)
                groups[(x.module, x.local)][name in sets[m]].append(name)
            split = [(k, v) for k, v in sorted(groups.items()) if v[True] and v[False]]
            if split:
                fail(f"{tool}'s relaxed set splits the instances of a module ({m}): "
                     f"the same register is relaxed in one and kept at the tick in "
                     f"another, which is a pattern that names one instance by its path:\n" +
                     "\n".join(f"  {mod} `{loc}`: relaxed in {v[True][0]}, at the tick in "
                               f"{v[False][0]}" for (mod, loc), v in split[:12]) +
                     (f"\n  ... and {len(split) - 12} more" if len(split) > 12 else ""))
    check_rev14(regs[REV14], xdc_slow[REV14], sdc_slow[REV14])
    return len(hits), sum(len(regs[m]) for m in MACHINES)


def check_rev14(regs, xdc_slow, sdc_slow):
    """Revision 14's every-tick registers are out of both relaxed sets, and
    every register of its memory system is classed (`REV14_CLASSED`)."""
    have = collections.defaultdict(set)
    for x in regs:
        have[x.module].add(x.local)
    for mod, classes in REV14_CLASSED.items():
        if mod not in have:
            fail(f"{mod} has no register in cadr_machine at revision 14, so revision "
                 f"14's classes of its registers hold nothing")
        unclassed = sorted(have[mod] - set(classes))
        if unclassed:
            fail(f"{mod} has registers revision 14's classes do not name, so nothing says "
                 f"whether the relaxed set may take them: {', '.join(unclassed)}; class each "
                 f"in tools/grid_check.py's REV14_CLASSED, `tick` or `held`")
        gone = sorted(set(classes) - have[mod])
        if gone:
            fail(f"{mod} at revision 14 has no register {', '.join(gone)}, which "
                 f"REV14_CLASSED names")
    for mod, names in REV14_NAMED_TICK.items():
        gone = sorted(set(names) - have[mod])
        if gone:
            fail(f"{mod} at revision 14 has no register {', '.join(gone)}, which "
                 f"REV14_NAMED_TICK names")
    for mod in REV14_OUT_WHOLE:
        if mod not in have:
            fail(f"{mod} has no register in cadr_machine at revision 14")
    tick = []
    for x in regs:
        if REV14_CLASSED.get(x.module, {}).get(x.local) == REV14_TICK \
                or x.local in REV14_NAMED_TICK.get(x.module, ()) \
                or x.module in REV14_OUT_WHOLE:
            tick.append(x)
    bad = [(tool, x) for x in tick
           for tool, name, slow in (("rtl/plumbing/xilinx7/cadr_machine.xdc", x.vivado, xdc_slow),
                                    ("boards/de25-nano/quartus/cadr_de25.sdc", x.quartus, sdc_slow))
           if name in slow]
    if bad:
        fail("revision 14's every-tick registers in the relaxed set, which would give "
             "their paths the microcycle where they have one tick:\n" +
             "\n".join(f"  {tool}: {x.module} `{x.local}`" for tool, x in bad[:24]) +
             (f"\n  ... and {len(bad) - 24} more" if len(bad) > 24 else ""))
    print(f"ok: revision 14's {len(tick)} every-tick registers are out of both relaxed sets, "
          f"and its memory system's {sum(len(c) for c in REV14_CLASSED.values())} registers "
          f"are each classed")


if __name__ == "__main__":
    main()
