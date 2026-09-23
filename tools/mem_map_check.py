#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Every written copy of a board's memory map says the same numbers.

WHY THIS EXISTS.  Where the machine's 128 MB sits in the processor's memory is
one fact per board, and it is written down in several files that no single
build reads together:

  - `rtl/plumbing/cadr_ddr_map.sv`, which the fabric is built from, one branch
    a board family (`CADR_DDR_MAP_DE25_NANO` chooses);
  - `boards/de25-nano/cadr_de25.sv`, which restates the DE25-Nano's main
    memory base so that a flow without the define stops at elaboration;
  - `cadr_board.h`, which every Linux program takes its addresses from;
  - each board's `cadr-reserved.dtsi`, the reserved-memory node that keeps the
    kernel off the region, by its unit address and by its `reg`;
  - `mksd-buildroot.sh`, which names the node it looks for on a card and the
    display windows it writes into the card's `fpgarc`;
  - on the DE25-Nano, `cadr_gpo` in U-Boot's environment, the system manager's
    GPO register, which sits one word below the GPI tally `cadr_board.h`
    names (TF-A's plat/intel/soc/agilex5/include/agilex5_system_manager.h,
    GPO at 0xE4 and GPI at 0xE8);
  - on the Zynq boards, the JTAG memory proofs' `MAIN_BASE`.

Each is right today.  A change to one of them builds, and each build is
self-consistent, so the first thing to notice would be a board: a device tree
that reserves less than the fabric writes lets the kernel hand the rest out as
ordinary memory, and the machine then writes over whatever Linux put there.

WHAT IT HOLDS.  For each board family, every copy against the fabric's
package: the reservation's base and size, main memory, the display and the
color display, the spare above the display, and on the DE25-Nano the GPO
register's page and offset against the tally's.  The package is the reference
only because it is the one the fabric is built from; any disagreement fails,
whichever side moved.

    python3 tools/mem_map_check.py . [--stamp build/mem_map.pass]
"""

import argparse
import os
import re
import sys

DDR_MAP = "rtl/plumbing/cadr_ddr_map.sv"
DE25_TOP = "boards/de25-nano/cadr_de25.sv"
BOARD_H = "boards/arty-z7-20/linux/buildroot/package/cadr-common/src/cadr/cadr_board.h"
DTSI = {
    "zynq": "boards/arty-z7-20/linux/cadr-reserved.dtsi",
    "de25": "boards/de25-nano/linux/cadr-reserved.dtsi",
}
MKSD = "boards/arty-z7-20/linux/mksd-buildroot.sh"
UBOOT_ENV = "boards/de25-nano/linux/buildroot/board/de25-nano/uboot/cadr_de25.env"
ZYNQ_TCL = ("boards/arty-z7-20/vivado/ddr_check.tcl",
            "boards/arty-z7-20/vivado/ddr_run.tcl")
NAMES = {"zynq": "the Zynq boards", "de25": "the DE25-Nano"}
# The system manager's GPO is the word below its GPI.  TF-A's
# agilex5_system_manager.h:53-54, SOCFPGA_SYSMGR_GPO 0xE4 and GPI 0xE8.
GPO_BELOW_GPI = 4
MB = 1 << 20

problems = []


def fail(msg):
    print("mem_map: " + msg, file=sys.stderr)
    sys.exit(1)


def disagree(msg):
    problems.append(msg)
    print("mem_map: " + msg, file=sys.stderr)


def read(root, path):
    p = os.path.join(root, path)
    if not os.path.exists(p):
        fail("%s is not there" % path)
    return open(p).read()


def preprocess(text, defined):
    """The package's text as a flow with or without `defined` would see it:
    `ifdef, `ifndef, `else and `endif, nested."""
    out, stack = [], []
    for line in text.splitlines():
        m = re.match(r"^\s*`(ifdef|ifndef)\s+(\w+)", line)
        if m:
            on = (m.group(2) in defined) == (m.group(1) == "ifdef")
            stack.append([on, all(s[0] for s in stack)])
            continue
        if re.match(r"^\s*`else\b", line):
            if not stack:
                fail("%s: an `else with no `ifdef" % DDR_MAP)
            stack[-1][0] = not stack[-1][0]
            continue
        if re.match(r"^\s*`endif\b", line):
            if not stack:
                fail("%s: an `endif with no `ifdef" % DDR_MAP)
            stack.pop()
            continue
        if all(s[0] for s in stack):
            out.append(line)
    if stack:
        fail("%s: an `ifdef with no `endif" % DDR_MAP)
    return "\n".join(out)


def sv_number(tok):
    tok = tok.strip().replace("_", "")
    m = re.fullmatch(r"(?:\d+)?'h([0-9A-Fa-f]+)", tok)
    if m:
        return int(m.group(1), 16)
    m = re.fullmatch(r"\d+", tok)
    if m:
        return int(tok)
    return None


def sv_expr(expr, known):
    """A constant expression of numbers, names already read, `+`, `*` and a
    `32'(x << n)` cast.  Anything else is refused rather than guessed."""
    e = expr.replace("32'(", "(")
    for name in sorted(known, key=len, reverse=True):
        e = re.sub(r"\b%s\b" % name, str(known[name]), e)
    e = re.sub(r"\d*'h([0-9A-Fa-f_]+)",
               lambda m: str(int(m.group(1).replace("_", ""), 16)), e)
    e = re.sub(r"(?<=\d)_(?=\d)", "", e)
    if not re.fullmatch(r"[0-9\s+*()<]+", e):
        fail("%s: cannot read %r as a constant" % (DDR_MAP, expr))
    return eval(e, {"__builtins__": {}})


def ddr_map(text, defined):
    body = preprocess(text, defined)
    raw, out = {}, {}
    for name, expr in re.findall(
            r"localparam\s+(?:logic\s*\[31:0\]|int\s+unsigned)\s+(\w+)\s*=\s*(.*?);",
            body, re.S):
        if name in raw:
            fail("%s defines %s twice for %s" % (DDR_MAP, name, sorted(defined) or "no define"))
        raw[name] = expr
    for name, expr in raw.items():
        v = sv_number(expr)
        if v is None:
            # Names used before this one are read first; the package is
            # written in dependency order.
            v = sv_expr(expr, {k: out[k] for k in out})
        out[name] = v
    for want in ("RESERVED_BASE", "RESERVED_MB", "MAIN_BASE", "MAIN_WORDS",
                 "DISPLAY_BASE", "DISPLAY_WORDS", "COLOR_DISPLAY_BASE"):
        if want not in out:
            fail("%s has no %s for %s" % (DDR_MAP, want, NAMES["de25" if defined else "zynq"]))
    return out


def board_h(text):
    m = re.search(r"#if defined\(CADR_BOARD_DE25_NANO\)\n(.*?)\n#else(.*?)\n#endif",
                  text, re.S)
    if not m:
        fail("%s has no CADR_BOARD_DE25_NANO half followed by an #else" % BOARD_H)
    halves = {}
    for fam, body in (("de25", m.group(1)), ("zynq", m.group(2))):
        d = {}
        for name, value in re.findall(r"^#define CADR_BOARD_(\w+)_HEX\s+([0-9A-Fa-f]+)\s*$",
                                      body, re.M):
            d[name] = int(value, 16)
        for name, value in re.findall(r"^#define CADR_BOARD_(TALLY_\w+)\s+0x([0-9A-Fa-f]+)u\s*$",
                                      body, re.M):
            d[name] = int(value, 16)
        halves[fam] = d
    return halves


def dtsi(text, path):
    """The reserved-memory node's unit address, and its reg as (base, size)
    at one or two cells each."""
    nodes = re.findall(r"cadr@([0-9A-Fa-f]+)\s*\{(.*?)\};", text, re.S)
    if len(nodes) != 1:
        fail("%s has %d cadr@ nodes, wanting one" % (path, len(nodes)))
    unit, body = nodes[0]
    m = re.search(r"\breg\s*=\s*<([^>]*)>", body)
    if not m:
        fail("%s: the cadr@%s node has no reg" % (path, unit))
    cells = [int(c, 16) for c in m.group(1).split()]
    if len(cells) == 2:
        base, size = cells
    elif len(cells) == 4:
        base, size = (cells[0] << 32) | cells[1], (cells[2] << 32) | cells[3]
    else:
        fail("%s: reg has %d cells, wanting two or four" % (path, len(cells)))
    return int(unit, 16), base, size


def mksd(text):
    """The card script's per-board facts: the de25-nano arm and the default."""
    m = re.search(r'^case "\$BOARD_NAME" in\n(.*?)^esac', text, re.S | re.M)
    if not m:
        fail("%s: the board case is not where this check looks" % MKSD)
    arms = re.split(r"^\s{2}(\S+)\)\s*$", m.group(1), flags=re.M)
    out = {}
    for label, body in zip(arms[1::2], arms[2::2]):
        fam = "de25" if label == "de25-nano" else "zynq" if label == "*" else None
        if fam is None:
            continue
        d = {}
        for k, v in re.findall(r"^\s*(RESERVED|DISPLAY_WINDOW|COLOR_WINDOW|DEBUG_WINDOW)=(\S+)",
                               body, re.M):
            d[k] = v
        out[fam] = d
    for fam in ("de25", "zynq"):
        if fam not in out:
            fail("%s has no arm for %s" % (MKSD, NAMES[fam]))
    return out


def env_value(text, name):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    m = re.findall(r"^%s=(\S+)\s*$" % re.escape(name), text, re.M)
    if len(m) != 1:
        fail("%s sets %s %d times, wanting once" % (UBOOT_ENV, name, len(m)))
    return int(m[0], 16)


def same(what, fam, pairs):
    """`pairs` is [(where, value)], the first the reference."""
    ref_where, ref = pairs[0]
    ok = True
    for where, v in pairs[1:]:
        if v != ref:
            disagree("%s, %s: %s says 0x%08X and %s says 0x%08X"
                     % (NAMES[fam], what, ref_where, ref, where, v))
            ok = False
    if ok:
        print("mem_map: %-16s %-26s 0x%08X in %d places"
              % (NAMES[fam], what, ref, len(pairs)))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", help="the repository's root")
    ap.add_argument("--stamp", help="write this file when the check passes")
    args = ap.parse_args()
    root = args.root

    pkg = read(root, DDR_MAP)
    maps = {"zynq": ddr_map(pkg, set()), "de25": ddr_map(pkg, {"CADR_DDR_MAP_DE25_NANO"})}
    header = board_h(read(root, BOARD_H))
    card = mksd(read(root, MKSD))

    m = re.findall(r"localparam\s+logic\s*\[31:0\]\s+MAIN_BASE\s*=\s*([^;]+);",
                   read(root, DE25_TOP))
    if len(m) != 1:
        fail("%s states MAIN_BASE %d times, wanting once" % (DE25_TOP, len(m)))
    de25_top_main = sv_number(m[0])

    for fam in ("zynq", "de25"):
        pm, h, c = maps[fam], header[fam], card[fam]
        for k in ("RESERVED", "MAIN", "DISPLAY", "COLOR", "SPARE", "CONSOLE"):
            if k not in h:
                fail("%s names no CADR_BOARD_%s_HEX for %s" % (BOARD_H, k, NAMES[fam]))
        unit, base, size = dtsi(read(root, DTSI[fam]), DTSI[fam])
        m = re.fullmatch(r"cadr@([0-9a-fA-F]+)", c.get("RESERVED", ""))
        if not m:
            fail("%s names no RESERVED=cadr@... node for %s" % (MKSD, NAMES[fam]))
        card_unit = int(m.group(1), 16)

        same("the reservation's base", fam, [
            (DDR_MAP + " RESERVED_BASE", pm["RESERVED_BASE"]),
            ("cadr_board.h RESERVED", h["RESERVED"]),
            (DTSI[fam] + " reg", base),
            (DTSI[fam] + " unit address", unit),
            (MKSD + " RESERVED", card_unit)])
        same("the reservation's size", fam, [
            (DDR_MAP + " RESERVED_MB", pm["RESERVED_MB"] * MB),
            (DTSI[fam] + " reg", size)])
        mains = [(DDR_MAP + " MAIN_BASE", pm["MAIN_BASE"]),
                 ("cadr_board.h MAIN", h["MAIN"])]
        if fam == "de25":
            mains.append((DE25_TOP + " MAIN_BASE", de25_top_main))
        else:
            for tcl in ZYNQ_TCL:
                t = re.findall(r"^set MAIN_BASE\s+0x([0-9A-Fa-f]+)\s*$", read(root, tcl), re.M)
                if len(t) != 1:
                    fail("%s sets MAIN_BASE %d times, wanting once" % (tcl, len(t)))
                mains.append((tcl + " MAIN_BASE", int(t[0], 16)))
        same("main memory", fam, mains)
        same("the display", fam, [
            (DDR_MAP + " DISPLAY_BASE", pm["DISPLAY_BASE"]),
            ("cadr_board.h DISPLAY", h["DISPLAY"]),
            (MKSD + " DISPLAY_WINDOW", int(c.get("DISPLAY_WINDOW", "0"), 16))])
        same("the color display", fam, [
            (DDR_MAP + " COLOR_DISPLAY_BASE", pm["COLOR_DISPLAY_BASE"]),
            ("cadr_board.h COLOR", h["COLOR"]),
            (MKSD + " COLOR_WINDOW", int(c.get("COLOR_WINDOW", "0"), 16))])
        same("the spare", fam, [
            (DDR_MAP + " DISPLAY_BASE + DISPLAY_WORDS * 4",
             pm["DISPLAY_BASE"] + pm["DISPLAY_WORDS"] * 4),
            ("cadr_board.h SPARE", h["SPARE"])])
        same("the debug window", fam, [
            ("cadr_board.h CONSOLE + 0x1000", h["CONSOLE"] + 0x1000),
            (MKSD + " DEBUG_WINDOW", int(c.get("DEBUG_WINDOW", "0"), 16))])
        # Main memory and the display inside the reservation, and the
        # reservation where the package says it ends.
        end = pm["RESERVED_BASE"] + pm["RESERVED_MB"] * MB
        for what, lo, n in (("main memory", pm["MAIN_BASE"], pm["MAIN_WORDS"] * 4),
                            ("the display", pm["DISPLAY_BASE"], pm["DISPLAY_WORDS"] * 4)):
            if lo < pm["RESERVED_BASE"] or lo + n > end:
                disagree("%s, %s: 0x%08X for %d MB is not inside the reservation "
                         "0x%08X-0x%08X" % (NAMES[fam], what, lo, n // MB,
                                            pm["RESERVED_BASE"], end - 1))

    gpo = env_value(read(root, UBOOT_ENV), "cadr_gpo")
    h = header["de25"]
    same("the GPO register", "de25", [
        ("cadr_board.h TALLY_PAGE + TALLY_OFF0 - 4",
         h["TALLY_PAGE"] + h["TALLY_OFF0"] - GPO_BELOW_GPI),
        (UBOOT_ENV + " cadr_gpo", gpo)])

    if problems:
        fail("the copies of a board's memory map disagree in %d place(s)" % len(problems))
    print("mem_map: every copy of both board families' memory maps agrees")
    if args.stamp:
        os.makedirs(os.path.dirname(args.stamp) or ".", exist_ok=True)
        open(args.stamp, "w").close()


if __name__ == "__main__":
    main()
