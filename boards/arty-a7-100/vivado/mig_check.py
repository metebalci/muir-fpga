#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Is the generated memory controller what the generator writes today, and is
# the project file it was generated from Digilent's with only the changes the
# repository says it has?
#
#     python3 boards/arty-a7-100/vivado/mig_check.py           # write what is derived
#     python3 boards/arty-a7-100/vivado/mig_check.py --check   # and is it current?
#
# WHY THIS EXISTS.  The Memory Interface Generator is this project's one
# generated-IP exception, taken because a DDR3 controller is a calibration
# sequence, a per-bit deskew physical layer and a bank manager, and nothing
# here could hold a hand-written one to anything.  What makes the exception
# honest is that the input is a text file in the repository, the run is a
# script, and the output is committed and CHECKED --- so a generated file that
# is not what the generator writes today is a failure and not a surprise.
# `boards/arty-z7-20/vivado/gen_ps7.py` is the same shape for the other board's
# processing system.
#
# THREE THINGS ARE ASKED.
#
#   1. **Is `mig.prj` Digilent's file with exactly four changes?**  The
#      published file is beside it, byte for byte, and the difference is
#      compared line for line against the list in `mig/README.md`.  A fourth
#      change --- a memory part, a timing parameter, a pin --- would be a
#      different memory and would pass unnoticed otherwise.
#   2. **Does regenerating give the same files?**  The controller is
#      regenerated into a scratch directory with the same relative layout and
#      compared.  Two lines are normalised and both are named below; nothing
#      else is forgiven.
#   3. **Is `cadr_a7_ddr_off.xdc` what this derives from the generated one?**
#      The memory-off board has the same DDR3L ports and no controller behind
#      them, so it needs their pins and standards without the physical layer's
#      slew rates, terminations and bufferless clock pair --- which are
#      meaningful only with the controller there.  Deriving it means the two
#      files cannot come apart, which is what "two descriptions of one layout
#      drift" is about.

import argparse
import filecmp
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
MIG = ROOT / "boards" / "arty-a7-100" / "mig"
GEN = MIG / "gen"
PRJ = MIG / "mig.prj"
DIGILENT = MIG / "mig-digilent-E.0-1.1.prj"
OFF_XDC = ROOT / "boards" / "arty-a7-100" / "cadr_a7_ddr_off.xdc"

# The generator stamps the hour it ran into a comment in each constraint file.
STAMP = re.compile(r"^##\s+\w{3}\s+\w{3}\s+\d+\s+[\d:]+\s+\d{4}\s*$")

# The four changes, as the repository states them.  A difference outside this
# list is a finding.
EXPECTED_DIFF = [
    ("-", "<SystemClock>Single-Ended</SystemClock>"),
    ("+", "<SystemClock>No Buffer</SystemClock>"),
    ("-", "<UIExtraClocks>1</UIExtraClocks>"),
    ("+", "<UIExtraClocks>0</UIExtraClocks>"),
    ("-", "<System_Clock>"),
    ("-", '<Pin Bank="35" PADName="E3(MRCC_P)" name="sys_clk_i"/>'),
    ("-", "</System_Clock>"),
    ("-", "<PortInterface>AXI</PortInterface>"),
    ("+", "<PortInterface>NATIVE</PortInterface>"),
    ("-", "<AXIParameters>"),
    ("-", "<C0_C_RD_WR_ARB_ALGORITHM>RD_PRI_REG</C0_C_RD_WR_ARB_ALGORITHM>"),
    ("-", "<C0_S_AXI_ADDR_WIDTH>28</C0_S_AXI_ADDR_WIDTH>"),
    ("-", "<C0_S_AXI_DATA_WIDTH>128</C0_S_AXI_DATA_WIDTH>"),
    ("-", "<C0_S_AXI_ID_WIDTH>4</C0_S_AXI_ID_WIDTH>"),
    ("-", "<C0_S_AXI_SUPPORTS_NARROW_BURST>0</C0_S_AXI_SUPPORTS_NARROW_BURST>"),
    ("-", "</AXIParameters>"),
]


def lines(path):
    return [l.strip() for l in path.read_text(encoding="utf-8-sig").splitlines()]


def prj_difference():
    """The changes made to Digilent's file, as a list of (sign, line)."""
    import difflib
    a, b = lines(DIGILENT), lines(PRJ)
    out = []
    for d in difflib.ndiff(a, b):
        if d.startswith("- ") and d[2:].strip():
            out.append(("-", d[2:].strip()))
        elif d.startswith("+ ") and d[2:].strip():
            out.append(("+", d[2:].strip()))
    return out


def derive_off_xdc():
    """The DDR3L pins for a board with no controller behind them."""
    src = GEN / "constraints" / "cadr_mig_a7.xdc"
    pins = {}
    vref = []
    order = []
    for line in src.read_text().splitlines():
        m = re.match(r"\s*set_property\s+(\S+)\s+(\S+)\s+\[get_ports\s+\{(\S+)\}\]",
                     line)
        if m:
            prop, val, port = m.group(1), m.group(2), m.group(3)
            if port not in pins:
                pins[port] = {}
                order.append(port)
            pins[port][prop] = val
            continue
        m = re.match(r"\s*set_property\s+INTERNAL_VREF\s+(\S+)\s+\[get_iobanks\s+(\S+)\]",
                     line)
        if m:
            vref.append((m.group(1), m.group(2)))

    out = [
        "# SPDX-FileCopyrightText: 2026 Mete Balci",
        "# SPDX-License-Identifier: AGPL-3.0-or-later",
        "#",
        "# GENERATED by boards/arty-a7-100/vivado/mig_check.py from the memory",
        "# controller's own generated constraints.  Do not edit; `make current`",
        "# fails if this is not what that script writes today.",
        "#",
        "# The DDR3L pins on a board with NO memory controller behind them.",
        "#",
        "# **WHY A SECOND FILE AND NOT THE GENERATED ONE.**  The ports are in",
        "# `cadr_arty_a7.sv`'s list whatever `DDR` says --- a port that exists",
        "# in only one configuration is a port list that differs between two",
        "# builds of one file --- so a memory-off board still has to say where",
        "# each one goes and what standard it drives.  What it must NOT say is",
        "# the rest of what the controller's file says: a slew rate, an input",
        "# termination and, for the two clock pins, no buffer at all.  Those",
        "# belong to the physical layer that drives them, and `IO_BUFFER_TYPE",
        "# NONE` on a port driven by ordinary logic is an error rather than a",
        "# warning.",
        "#",
        "# **AND THE DIFFERENTIAL PAIRS BECOME SINGLE-ENDED HERE**, which is",
        "# the one substantive difference.  `DIFF_SSTL135` requires a",
        "# differential buffer, and with no controller there is none: the four",
        "# pins are driven low or let go, and the memory part is held in reset",
        "# by `ddr3_reset_n` regardless.",
        "#",
        "# Read only when the controller is absent; the generated file is read",
        "# in its place when it is present, and it sets these same pins to the",
        "# same places.",
        "",
    ]
    for port in order:
        p = pins[port]
        std = p.get("IOSTANDARD", "SSTL135")
        std = "SSTL135" if std.startswith("DIFF_") else std
        out.append("set_property -dict { PACKAGE_PIN %s   IOSTANDARD %s } "
                   "[get_ports { %s }]" % (p["PACKAGE_PIN"], std, port))
    out.append("")
    for value, bank in vref:
        out.append("# The bank's reference, which the inputs on it need whatever")
        out.append("# is driving them.")
        out.append("set_property INTERNAL_VREF %s [get_iobanks %s]" % (value, bank))
    out.append("")
    return "\n".join(out)


def regenerate(dest):
    """Run the generator into `dest`, with the same relative layout."""
    vivado = shutil.which("vivado")
    if vivado is None:
        return None
    tmp = pathlib.Path(dest)
    for rel in ["boards/arty-a7-100/mig", "boards/arty-a7-100/vivado"]:
        (tmp / rel).mkdir(parents=True, exist_ok=True)
    shutil.copy2(PRJ, tmp / "boards/arty-a7-100/mig/mig.prj")
    shutil.copy2(ROOT / "boards/arty-a7-100/vivado/mig.tcl",
                 tmp / "boards/arty-a7-100/vivado/mig.tcl")
    r = subprocess.run([vivado, "-mode", "batch", "-nojournal",
                        "-log", str(tmp / "mig.log"),
                        "-source", "boards/arty-a7-100/vivado/mig.tcl"],
                       cwd=tmp, capture_output=True, text=True)
    if r.returncode != 0:
        print("mig: the generator failed:\n" + r.stdout[-2000:], file=sys.stderr)
        sys.exit(1)
    return tmp / "boards/arty-a7-100/mig/gen"


def same(a, b):
    """Two generated files, with the generator's own hour stamp normalised."""
    ta = [l for l in a.read_text(errors="replace").splitlines()
          if not STAMP.match(l)]
    tb = [l for l in b.read_text(errors="replace").splitlines()
          if not STAMP.match(l)]
    return ta == tb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="fail if anything is not what this writes today")
    args = ap.parse_args()

    # ---- 1. the project file
    diff = prj_difference()
    if diff != EXPECTED_DIFF:
        print("mig: FAILED --- boards/arty-a7-100/mig/mig.prj is not Digilent's",
              file=sys.stderr)
        print("mig: file with the four changes the README states.  What differs:",
              file=sys.stderr)
        for sign, line in diff:
            print("mig:   %s %s" % (sign, line), file=sys.stderr)
        return 1
    print("mig: ok --- mig.prj is Digilent's E.0/1.1 file with the four"
          " documented changes")

    # ---- 2. the derived constraints for a memory-off board
    text = derive_off_xdc()
    if args.check:
        if not OFF_XDC.exists() or OFF_XDC.read_text() != text:
            print("mig: FAILED --- %s is stale; run"
                  " `python3 boards/arty-a7-100/vivado/mig_check.py` and commit"
                  % OFF_XDC.relative_to(ROOT), file=sys.stderr)
            return 1
        print("mig: ok --- cadr_a7_ddr_off.xdc is derived from the generated"
              " constraints")
    else:
        OFF_XDC.write_text(text)
        print("mig: wrote %s" % OFF_XDC.relative_to(ROOT))

    # ---- 3. the generated tree itself
    if shutil.which("vivado") is None:
        print("mig: skipped the regeneration --- vivado is not on PATH, so this"
              " host cannot say whether the generated controller is current")
        return 0
    if not args.check:
        print("mig: not regenerating the controller; run"
              " `vivado -mode batch -source boards/arty-a7-100/vivado/mig.tcl`")
        return 0

    with tempfile.TemporaryDirectory(prefix="migcheck-") as d:
        fresh = regenerate(d)
        bad = []
        here = {p.relative_to(GEN) for p in GEN.rglob("*") if p.is_file()}
        there = {p.relative_to(fresh) for p in fresh.rglob("*") if p.is_file()}
        for rel in sorted(here - there):
            bad.append("only in the repository: %s" % rel)
        for rel in sorted(there - here):
            bad.append("only in a fresh run: %s" % rel)
        for rel in sorted(here & there):
            if not same(GEN / rel, fresh / rel):
                bad.append("differs: %s" % rel)
        if bad:
            print("mig: FAILED --- the committed controller is not what the"
                  " generator writes today:", file=sys.stderr)
            for b in bad[:20]:
                print("mig:   %s" % b, file=sys.stderr)
            if len(bad) > 20:
                print("mig:   ... and %d more" % (len(bad) - 20), file=sys.stderr)
            return 1
        print("mig: ok --- %d generated file(s) are what the generator writes"
              " today" % len(here))
    return 0


if __name__ == "__main__":
    sys.exit(main())
