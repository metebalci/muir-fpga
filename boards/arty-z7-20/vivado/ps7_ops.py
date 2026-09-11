# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What `ps7_init` actually writes, as an ordered list, so that it can be
# checked.
#
#     python3 boards/arty-z7-20/vivado/ps7_ops.py            # regenerate boards/arty-z7-20/vivado/ps7_init.ops
#     python3 boards/arty-z7-20/vivado/ps7_ops.py --check    # is it what the flow writes today?
#     python3 boards/arty-z7-20/vivado/ps7_ops.py --from F   # extract from an existing routine
#
# WHY THE OPS AND NOT THE ROUTINE.  `boards/arty-z7-20/vivado/gen_ps7_init.tcl` writes an 853
# line `ps7_init.tcl` whose text carries the tool's formatting and no licence
# header of any kind.  Committing that would put an unheadered generated file
# in a tree whose rule is SPDX on every source file, and would compare two
# tools' formatting rather than their effect.  What matters is the ordered
# sequence of register operations, which is what the board sees, and which
# this extracts: `mask_write`, `mwr -force` (rewritten as a full-mask write,
# because that is what it is), `mask_poll` and `mask_delay`, each tagged with
# the proc it is in.  Committed as boards/arty-z7-20/vivado/ps7_init.ops, checked by
# `make current`.
#
# THE COMPARISON THIS MAKES POSSIBLE, and the reason the file exists.
# Measured 2026-09-09 under Vivado 2026.1: the routine generated from
# boards/arty-z7-20/vivado/ps7_config.tcl agrees with the one in Digilent's 2017.4 PetaLinux BSP
# --- a different tool, eight releases apart --- on every DDR, PLL, MIO and
# post-config write, character for character across all three silicon
# revisions.  They differ in six writes and four delays per revision, in
# `ps7_clock_init` and `ps7_peripherals_init`, and every one is explained by
# the two designs' own configurations.  `--from` is how that was done and how
# it is redone: extract both, diff the two .ops files.
#
# THE EXTRACTION IS NOT TAKEN ON TRUST.  It was cross-checked against a second
# method --- whitespace-normalised comparison of whole proc bodies --- which
# agreed, and self-tested against two mutations of a generated routine: a
# one-bit change to a DDR value and a deleted `0xF8000900` line are both
# reported, the second on all three revisions.  A comparison that cannot fail
# is worth nothing, and this project has met that failure before.
#
# WITHOUT VIVADO IT SKIPS AND SAYS SO, on `rtl_sys.golden`'s and
# `boards/arty-z7-20/vivado/gen_ps7.py`'s precedent: CI has no Vivado, the committed file is the
# point, and a check that cannot run must say it did not run rather than fail.

import argparse
import difflib
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

OPS = os.path.join(HERE, "ps7_init.ops")
GEN = os.path.join("boards", "arty-z7-20", "vivado", "gen_ps7_init.tcl")
OUTDIR = os.path.join("build", "ps7")

SPDX = ("# SPDX-FileCopyrightText: 2026 Mete Balci\n"
        "# SPDX-License-Identifier: AGPL-3.0-or-later")

# The four things a routine does.  `mask_read` is in the vocabulary and has
# never appeared in one of these; if it ever does it is an operation and must
# be extracted rather than dropped, which is why it is named here.
VERBS = ("mask_write", "mwr", "mask_poll", "mask_delay", "mask_read")

# The routine must contain these, or the extraction has found no real writes
# and an empty comparison would pass.  `0xF8000900` is LVL_SHFTR_EN and
# `0xF8000240` is FPGA_RST_CTRL, the two writes of `ps7_post_config` --- the
# ones that make `S_AXI_HP0` live.
LANDMARKS = ("0xF8000900", "0xF8000240")


def die(msg):
    sys.stderr.write("ps7_ops: %s\n" % msg)
    sys.exit(1)


def extract(path):
    """The ordered register operations of a ps7_init.tcl, one to a line."""
    out = []
    proc = None
    with open(path) as f:
        for line in f:
            s = line.strip()
            m = re.match(r"^proc\s+(\S+)", s)
            if m:
                proc = m.group(1)
                continue
            if proc is None or s == "}":
                proc = None if s == "}" else proc
                continue
            word = s.split()
            if not word or word[0] not in VERBS:
                continue
            verb = word[0]
            arg = [a for a in word[1:] if not a.startswith("-")]
            if verb == "mwr":
                # `mwr -force ADDR VAL` is a write of every bit.  Saying so
                # here is what lets a full-mask write and a masked write of
                # the same register be compared as the same kind of thing.
                verb, arg = "mask_write", [arg[0], "0xFFFFFFFF", arg[1]]
            norm = []
            for a in arg:
                try:
                    norm.append("0x%08X" % int(a, 0))
                except ValueError:
                    norm.append(a)
            out.append("%-32s %-11s %s" % (proc, verb, " ".join(norm)))
    if not out:
        die("%s: no register operations --- this is not a ps7_init.tcl"
            % path)
    for want in LANDMARKS:
        if not any(want in line for line in out):
            die("%s: no write to %s --- the extraction is not finding real "
                "writes" % (path, want))
    return out


def rendered(ops):
    """The committed file.  Nothing in it may depend on where it was run.

    No path, no tool version, no date: the claim is that the flow writes
    these operations, and a header carrying the OUTDIR someone happened to
    set, or the Vivado they happened to have, would fail `make current` for
    reasons that are not about the routine.
    """
    head = [SPDX, "#",
            "# GENERATED by boards/arty-z7-20/vivado/ps7_ops.py from the ps7_init.tcl that",
            "# boards/arty-z7-20/vivado/gen_ps7_init.tcl writes out of boards/arty-z7-20/vivado/ps7_config.tcl.",
            "# Do not edit; run `make ps7-init`.",
            "#",
            "# Every register operation the Zynq start-up routine performs,"
            " in order, one to",
            "# a line: the proc, the verb, the register, and the mask and"
            " value where the",
            "# verb has them.  `mwr -force` is written as a full-mask"
            " `mask_write`, because",
            "# that is what it is.",
            "#",
            "# This is the claim.  The routine itself is regenerated into"
            " $OUTDIR and is not",
            "# committed: it carries no licence header of any kind, and its"
            " text would",
            "# compare two tools' formatting rather than their effect.  See"
            " boards/arty-z7-20/vivado/ps7_ops.py",
            "# for what was measured against what, and"
            " boards/arty-z7-20/vivado/ps7_config.tcl for where the",
            "# configuration came from.",
            "#",
            "# %d operations, %d procs."
            % (ops_count(ops), procs_count(ops)),
            ""]
    return "\n".join(head + ops) + "\n"


def ops_count(ops):
    return len(ops)


def procs_count(ops):
    return len(set(line.split()[0] for line in ops))


def committed():
    try:
        with open(OPS) as f:
            return [l.rstrip("\n") for l in f
                    if l.strip() and not l.startswith("#")]
    except IOError:
        die("boards/arty-z7-20/vivado/ps7_init.ops is missing: run `make ps7-init` and commit it")


def register(line):
    """The register a line names, for a message that points somewhere."""
    word = line.split()
    return word[2] if len(word) > 2 else "?"


def report(have, want):
    """Say WHICH register moved, not merely that something did.

    Aligned with difflib rather than compared position by position: a lost
    or gained operation shifts every line after it, and eight cascaded
    "committed X, generated Y" lines point at the wrong place.  What is
    wanted is the one operation that went.
    """
    said = 0
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(
            None, have, want, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        for k in range(i1, i2):
            if said >= 8:
                break
            said += 1
            sys.stderr.write(
                "ps7_ops:   line %d: committed, and the flow does not write "
                "it: %s %s\n" % (k + 1, register(have[k]), have[k].strip()))
        for k in range(j1, j2):
            if said >= 8:
                break
            said += 1
            sys.stderr.write(
                "ps7_ops:   line %d: the flow writes it, and it is not "
                "committed: %s %s\n"
                % (k + 1, register(want[k]), want[k].strip()))
        if said >= 8:
            sys.stderr.write("ps7_ops:   ... and more\n")
            break


def vivado():
    root = os.environ.get("XILINX_VIVADO")
    if root:
        exe = os.path.join(root, "bin", "vivado")
        if os.path.exists(exe):
            return exe
    return shutil.which("vivado")


def generate():
    """Run the IP flow and return the routine it wrote, or None without it."""
    exe = vivado()
    if exe is None:
        return None
    os.chdir(REPO)
    log = os.path.join(OUTDIR, "gen_ps7_init.log")
    if not os.path.isdir(OUTDIR):
        os.makedirs(OUTDIR)
    proc = subprocess.run(
        [exe, "-mode", "batch", "-nojournal", "-log", log, "-source", GEN],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    text = proc.stdout.decode("utf-8", "replace")
    if proc.returncode != 0 or "gen_ps7_init: ok" not in text:
        sys.stderr.write(text[-4000:])
        die("%s did not finish; its log is %s" % (GEN, log))
    return os.path.join(OUTDIR, "ps7_init.tcl")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="compare the committed .ops with what the flow writes")
    ap.add_argument("--from", dest="src", metavar="PS7_INIT_TCL",
                    help="extract from this routine instead of generating one")
    args = ap.parse_args()

    if args.src:
        for line in extract(args.src):
            print(line)
        return 0

    src = generate()
    if src is None:
        # Not a failure.  CI has no Vivado and the committed file is the point.
        print("ps7_ops: skipped --- no vivado on PATH or in $XILINX_VIVADO")
        return 0

    ops = extract(src)
    if args.check:
        have = committed()
        if have != ops:
            sys.stderr.write(
                "ps7_ops: boards/arty-z7-20/vivado/ps7_init.ops is not what the flow writes "
                "today\n")
            report(have, ops)
            die("run `make ps7-init` and commit, or find out why the routine "
                "moved")
        print("ps7_ops: ok: boards/arty-z7-20/vivado/ps7_init.ops is current (%d operations, "
              "%d procs)" % (ops_count(ops), procs_count(ops)))
        return 0

    with open(OPS, "w") as f:
        f.write(rendered(ops))
    print("ps7_ops: wrote boards/arty-z7-20/vivado/ps7_init.ops (%d operations, %d procs)"
          % (ops_count(ops), procs_count(ops)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
