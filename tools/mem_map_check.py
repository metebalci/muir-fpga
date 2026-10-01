#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Every written copy of a board's memory map says the same numbers.

WHY THIS EXISTS.  Where the machine's reservation sits in the processor's
memory is one fact per board, and it is written down in several files that no single
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
  - on the Zynq boards, the JTAG memory proofs' `MAIN_BASE`;
  - for QUUX revision 13, which has a device tree of its own on the Arty
    Z7-20 and the DE25-Nano: `quux13-reserved.dtsi`, the node the card
    script names for REVISION=13, and the records' size the disk pack
    program maps.

Each is right today.  A change to one of them builds, and each build is
self-consistent, so the first thing to notice would be a board: a device tree
that reserves less than the fabric writes lets the kernel hand the rest out as
ordinary memory, and the machine then writes over whatever Linux put there.

WHAT IT HOLDS.  First the layout itself, in the package, for each board
family: main memory 16 MB (4M words at 4 bytes a word, which holds the whole
22-bit space and so the 60 boards the machine can fit), the display 1 MB
(both TV boards' buffers, and QUUX's video controller's 64K words), the disk
pack program's records after it, the three abutting in that order from the
reservation's base, none meeting another, and the reservation exactly their
sum.  Then, for each board family, every copy against the fabric's
package: the reservation's base and size, main memory, the display and the
color display, the records above the display, and on the DE25-Nano the GPO
register's page and offset against the tally's.  And for QUUX revision 13, on
the boards that run it: its main memory and room, the records' size, its own
reservation from its main memory to the end of the records, and that its
packed main memory (5 bytes a word) ends at the display.  The package is the reference
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
# QUUX revision 13's own reservation, in its own tree, on the boards that run
# it (the Cora Z7-07S cannot build QUUX, and has no revision 13 tree).
QUUX13_DTSI = {
    "zynq": "boards/arty-z7-20/linux/quux13-reserved.dtsi",
    "de25": "boards/de25-nano/linux/quux13-reserved.dtsi",
}
FEEDER_H = "boards/arty-z7-20/linux/buildroot/package/cadr-disk-packs/src/pack_feeder.h"
# The system manager's GPO is the word below its GPI.  TF-A's
# agilex5_system_manager.h:53-54, SOCFPGA_SYSMGR_GPO 0xE4 and GPI 0xE8.
GPO_BELOW_GPI = 4
MB = 1 << 20
KB = 1 << 10
# THE LAYOUT OF THE CADR's RESERVATION, decided once for every board: main
# memory, the display and the records, in that order from the reservation's
# base.  The package is held to these numbers, and every copy to the package.
LAYOUT_MAIN_BYTES = 16 * MB      # 4M words at 4 bytes a word
LAYOUT_DISPLAY_BYTES = 1 * MB    # both TV boards' buffers, 256 KB in use
# The CADR's physical address is 22 bits; `main_byte_address` makes any of
# them.  And the most a QUUX video controller's buffer is, 64K words.
PHYS_WORDS = 1 << 22
TV_BUFFER_WORDS = 32768

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
    for want in ("RESERVED_BASE", "RESERVED_BYTES", "MAIN_BASE", "MAIN_WORDS",
                 "MAIN_WORDS_REACHABLE", "DISPLAY_BASE", "DISPLAY_WORDS",
                 "DISPLAY_WORDS_REACHABLE", "COLOR_DISPLAY_BASE", "VIDEO_WORDS_MAX",
                 "QUUX13_MAIN_BASE", "QUUX13_MAIN_WORDS_MAX", "RECORDS_BYTES",
                 "QUUX13_RESERVED_END"):
        if want not in out:
            fail("%s has no %s for %s" % (DDR_MAP, want, NAMES["de25" if defined else "zynq"]))
    return out


def layout(fam, pm):
    """The package's own layout for one board family, against the decided
    sizes: main memory, the display and the records abutting from the
    reservation's base in that order, none meeting another, every address the
    machine can make inside its area, and the reservation exactly their sum."""
    base, size = pm["RESERVED_BASE"], pm["RESERVED_BYTES"]
    main = (pm["MAIN_BASE"], pm["MAIN_WORDS"] * 4)
    display = (pm["DISPLAY_BASE"], pm["DISPLAY_WORDS"] * 4)
    records = (display[0] + display[1], pm["RECORDS_BYTES"])
    areas = (("main memory", main), ("the display", display), ("the records", records))
    before = len(problems)
    if main[1] != LAYOUT_MAIN_BYTES:
        disagree("%s: main memory is %d KB, and the layout's is %d KB"
                 % (NAMES[fam], main[1] // KB, LAYOUT_MAIN_BYTES // KB))
    if display[1] != LAYOUT_DISPLAY_BYTES:
        disagree("%s: the display is %d KB, and the layout's is %d KB"
                 % (NAMES[fam], display[1] // KB, LAYOUT_DISPLAY_BYTES // KB))
    if main[0] != base:
        disagree("%s: main memory at 0x%08X is not at the reservation's base 0x%08X"
                 % (NAMES[fam], main[0], base))
    if display[0] != main[0] + main[1]:
        disagree("%s: the display at 0x%08X does not begin where main memory ends, 0x%08X"
                 % (NAMES[fam], display[0], main[0] + main[1]))
    if size != main[1] + display[1] + records[1]:
        disagree("%s: the reservation is 0x%X bytes, and main memory, the display and the "
                 "records are 0x%X" % (NAMES[fam], size, main[1] + display[1] + records[1]))
    for what, (lo, n) in areas:
        if lo < base or lo + n > base + size:
            disagree("%s: %s at 0x%08X-0x%08X is not inside the reservation 0x%08X-0x%08X"
                     % (NAMES[fam], what, lo, lo + n - 1, base, base + size - 1))
    for i, (w1, (a1, n1)) in enumerate(areas):
        for w2, (a2, n2) in areas[i + 1:]:
            if a1 < a2 + n2 and a2 < a1 + n1:
                disagree("%s: %s at 0x%08X-0x%08X meets %s at 0x%08X-0x%08X"
                         % (NAMES[fam], w1, a1, a1 + n1 - 1, w2, a2, a2 + n2 - 1))
    # What the machines make, each inside its own area: any 22-bit address
    # (the CADR's and QUUX revision 12's main memory, and the 60 boards among
    # them), the two TV boards' buffers, and QUUX's video controller's.
    for what, n, room in (("the 22-bit space", PHYS_WORDS * 4, main[1]),
                          ("60 boards", pm["MAIN_WORDS_REACHABLE"] * 4, main[1]),
                          ("QUUX's video buffer", pm["VIDEO_WORDS_MAX"] * 4, display[1])):
        if n > room:
            disagree("%s: %s is 0x%X bytes and its area 0x%X" % (NAMES[fam], what, n, room))
    if pm["DISPLAY_WORDS_REACHABLE"] != TV_BUFFER_WORDS:
        disagree("%s: a TV board's buffer is %d words, not %d"
                 % (NAMES[fam], pm["DISPLAY_WORDS_REACHABLE"], TV_BUFFER_WORDS))
    tv_end = pm["COLOR_DISPLAY_BASE"] + TV_BUFFER_WORDS * 4
    if pm["COLOR_DISPLAY_BASE"] < display[0] + TV_BUFFER_WORDS * 4 or tv_end > display[0] + display[1]:
        disagree("%s: the color TV's buffer at 0x%08X-0x%08X is not in the display's area "
                 "above the first board's" % (NAMES[fam], pm["COLOR_DISPLAY_BASE"], tv_end - 1))
    if pm["QUUX13_RESERVED_END"] != base + size:
        disagree("%s: revision 13's reservation ends at 0x%08X, the CADR's at 0x%08X; both end "
                 "with the records" % (NAMES[fam], pm["QUUX13_RESERVED_END"], base + size))
    if len(problems) == before:
        print("mem_map: %-16s the layout: main memory 0x%08X, %d MB; the display 0x%08X, "
              "%d MB; the records 0x%08X, %d KB; 0x%X bytes in all"
              % (NAMES[fam], main[0], main[1] // MB, display[0], display[1] // MB,
                 records[0], records[1] // KB, size))


def board_h(text):
    m = re.search(r"#if defined\(CADR_BOARD_DE25_NANO\)\n(.*?)\n#else(.*?)\n#endif",
                  text, re.S)
    if not m:
        fail("%s has no CADR_BOARD_DE25_NANO half followed by an #else" % BOARD_H)
    halves = {}
    records = re.findall(r"^#define CADR_BOARD_RECORDS_BYTES\s+0x([0-9A-Fa-f]+)u\s*$", text, re.M)
    for fam, body in (("de25", m.group(1)), ("zynq", m.group(2))):
        d = {}
        for name, value in re.findall(r"^#define CADR_BOARD_(\w+)_HEX\s+([0-9A-Fa-f]+)\s*$",
                                      body, re.M):
            d[name] = int(value, 16)
        for name, value in re.findall(r"^#define CADR_BOARD_(TALLY_\w+)\s+0x([0-9A-Fa-f]+)u\s*$",
                                      body, re.M):
            d[name] = int(value, 16)
        m = re.findall(r"^#define CADR_BOARD_QUUX13_MAIN_WORDS_MAX\s+\((\d+)u \* 1024u \* 1024u\)\s*$",
                       body, re.M)
        if len(m) == 1:
            d["QUUX13_WORDS"] = int(m[0]) << 20
        if len(records) == 1:
            d["RECORDS"] = int(records[0], 16)
        halves[fam] = d
    return halves


def dtsi(text, path):
    """The reserved-memory node's unit address, and its reg as (base, size)
    at one or two cells each."""
    nodes = re.findall(r"(?:cadr|quux13)@([0-9A-Fa-f]+)\s*\{(.*?)\};", text, re.S)
    if len(nodes) != 1:
        fail("%s has %d cadr@ or quux13@ nodes, wanting one" % (path, len(nodes)))
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
    # REVISION=13's own arms, one a board that runs it.
    m = re.search(r'^case "\$REVISION" in\n(.*?)^esac', text, re.S | re.M)
    if not m:
        fail("%s: the REVISION case is not where this check looks" % MKSD)
    for label, fam in (("arty-z7-20", "zynq"), ("de25-nano", "de25")):
        r = re.search(r"^\s*%s\)\s*$(.*?);;" % re.escape(label), m.group(1), re.S | re.M)
        v = re.findall(r"^\s*RESERVED=(\S+)", r.group(1), re.M) if r else []
        if len(v) != 1:
            fail("%s: REVISION=13 on %s names %d RESERVED, wanting one" % (MKSD, label, len(v)))
        out[fam]["RESERVED13"] = v[0]
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


KR260_TOP = "boards/kria-kr260/cadr_kr260.sv"
KR260_DTSI = "boards/kria-kr260/linux/cadr-reserved.dtsi"


def kr260(root, pkg):
    """The Kria KR260's copies: the package under `CADR_DDR_MAP_KR260`, the
    KR260 half of `cadr_board.h`, the card's reservation, and the top level's
    own statement of its base and of its faces' windows."""
    fam = "kr260"
    NAMES[fam] = "the Kria KR260"
    pm = ddr_map(pkg, {"CADR_DDR_MAP_KR260"})
    text = read(root, BOARD_H)
    m = re.search(r"\n#else  // CADR_BOARD_KR260[^\n]*\n(.*?)\n#endif  // CADR_BOARD_KR260", text, re.S)
    if not m:
        fail("%s has no CADR_BOARD_KR260 half" % BOARD_H)
    h = {}
    for name, value in re.findall(r"^#define CADR_BOARD_(\w+)_HEX\s+([0-9A-Fa-f]+)\s*$", m.group(1), re.M):
        h[name] = int(value, 16)
    w = re.findall(r"^#define CADR_BOARD_QUUX13_MAIN_WORDS_MAX\s+\((\d+)u \* 1024u \* 1024u\)\s*$",
                   m.group(1), re.M)
    if len(w) != 1:
        fail("%s names no revision 13 room for %s" % (BOARD_H, NAMES[fam]))
    for k in ("RESERVED", "MAIN", "DISPLAY", "COLOR", "SPARE", "CONSOLE", "QUUX13_MAIN",
              "PACK", "CHAOS", "SERIAL", "INPUT", "FD"):
        if k not in h:
            fail("%s names no CADR_BOARD_%s_HEX for %s" % (BOARD_H, k, NAMES[fam]))
    top = read(root, KR260_TOP)

    def top_value(name):
        v = re.findall(r"\b%s\s*\(\s*32'h([0-9A-Fa-f_]+)\s*\)" % name, top)
        if name == "MAIN_BASE":
            v = re.findall(r"localparam\s+logic\s*\[31:0\]\s+MAIN_BASE\s*=\s*32'h([0-9A-Fa-f_]+)\s*;", top)
        if len(v) != 1:
            fail("%s states %s %d times, wanting once" % (KR260_TOP, name, len(v)))
        return int(v[0].replace("_", ""), 16)

    unit, base, size = dtsi(read(root, KR260_DTSI), KR260_DTSI)
    same("the reservation's base", fam, [
        (DDR_MAP + " RESERVED_BASE", pm["RESERVED_BASE"]),
        ("cadr_board.h RESERVED", h["RESERVED"]),
        (KR260_DTSI + " reg", base),
        (KR260_DTSI + " unit address", unit)])
    same("the reservation's size", fam, [
        (DDR_MAP + " RESERVED_BYTES", pm["RESERVED_BYTES"]),
        (KR260_DTSI + " reg", size)])
    same("main memory", fam, [
        (DDR_MAP + " MAIN_BASE", pm["MAIN_BASE"]),
        ("cadr_board.h MAIN", h["MAIN"]),
        (KR260_TOP + " MAIN_BASE", top_value("MAIN_BASE"))])
    same("the display", fam, [
        (DDR_MAP + " DISPLAY_BASE", pm["DISPLAY_BASE"]),
        ("cadr_board.h DISPLAY", h["DISPLAY"])])
    same("the color display", fam, [
        (DDR_MAP + " COLOR_DISPLAY_BASE", pm["COLOR_DISPLAY_BASE"]),
        ("cadr_board.h COLOR", h["COLOR"])])
    same("the records", fam, [
        (DDR_MAP + " DISPLAY_BASE + DISPLAY_WORDS * 4", pm["DISPLAY_BASE"] + pm["DISPLAY_WORDS"] * 4),
        ("cadr_board.h SPARE", h["SPARE"])])
    same("revision 13's main memory", fam, [
        (DDR_MAP + " QUUX13_MAIN_BASE", pm["QUUX13_MAIN_BASE"]),
        ("cadr_board.h QUUX13_MAIN", h["QUUX13_MAIN"])])
    same("revision 13's room, words", fam, [
        (DDR_MAP + " QUUX13_MAIN_WORDS_MAX", pm["QUUX13_MAIN_WORDS_MAX"]),
        ("cadr_board.h QUUX13_MAIN_WORDS_MAX", int(w[0]) << 20)])
    end13 = pm["QUUX13_MAIN_BASE"] + 5 * pm["QUUX13_MAIN_WORDS_MAX"]
    if end13 != pm["DISPLAY_BASE"]:
        disagree("%s: revision 13's main memory, 5 bytes a word, ends at 0x%08X and the "
                 "display begins at 0x%08X" % (NAMES[fam], end13, pm["DISPLAY_BASE"]))
    layout(fam, pm)
    # The faces' windows: where the programs look and where the fabric answers.
    for k, param in (("PACK", "PACK_BASE"), ("CHAOS", "CHAOS_BASE"), ("SERIAL", "SER_BASE"),
                     ("INPUT", "INPUT_BASE"), ("FD", "FD_BASE")):
        same("the %s face" % k.lower(), fam, [
            ("cadr_board.h " + k, h[k]), (KR260_TOP + " " + param, top_value(param))])
    same("the console", fam, [
        ("cadr_board.h CONSOLE", h["CONSOLE"]), (KR260_TOP + " CON_BASE", top_value("CON_BASE"))])
    same("the debug window", fam, [
        ("cadr_board.h CONSOLE + 0x1000", h["CONSOLE"] + 0x1000),
        (KR260_TOP + " DBG_BASE", top_value("DBG_BASE"))])


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
            (DDR_MAP + " RESERVED_BYTES", pm["RESERVED_BYTES"]),
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
        same("the records", fam, [
            (DDR_MAP + " DISPLAY_BASE + DISPLAY_WORDS * 4",
             pm["DISPLAY_BASE"] + pm["DISPLAY_WORDS"] * 4),
            ("cadr_board.h SPARE", h["SPARE"])])
        same("the debug window", fam, [
            ("cadr_board.h CONSOLE + 0x1000", h["CONSOLE"] + 0x1000),
            (MKSD + " DEBUG_WINDOW", int(c.get("DEBUG_WINDOW", "0"), 16))])
        # The layout inside the reservation.
        layout(fam, pm)

    # QUUX revision 13's own reservation, from its main memory to the end of
    # the records, and nothing in its main memory but main memory.
    feeder = re.findall(r"^#define FEEDER_MAP_BYTES\s+0x([0-9A-Fa-f]+)u\s*$", read(root, FEEDER_H), re.M)
    if len(feeder) != 1:
        fail("%s states FEEDER_MAP_BYTES %d times, wanting once" % (FEEDER_H, len(feeder)))
    for fam in ("zynq", "de25"):
        pm, h, c = maps[fam], header[fam], card[fam]
        if "QUUX13_MAIN" not in h or "QUUX13_WORDS" not in h or "RECORDS" not in h:
            fail("%s names no revision 13 main memory, room or records for %s" % (BOARD_H, NAMES[fam]))
        same("revision 13's main memory", fam, [
            (DDR_MAP + " QUUX13_MAIN_BASE", pm["QUUX13_MAIN_BASE"]),
            ("cadr_board.h QUUX13_MAIN", h["QUUX13_MAIN"])])
        same("revision 13's room, words", fam, [
            (DDR_MAP + " QUUX13_MAIN_WORDS_MAX", pm["QUUX13_MAIN_WORDS_MAX"]),
            ("cadr_board.h QUUX13_MAIN_WORDS_MAX", h["QUUX13_WORDS"])])
        same("the records' size", fam, [
            (DDR_MAP + " RECORDS_BYTES", pm["RECORDS_BYTES"]),
            ("cadr_board.h RECORDS_BYTES", h["RECORDS"]),
            (FEEDER_H + " FEEDER_MAP_BYTES", int(feeder[0], 16))])
        unit, base, size = dtsi(read(root, QUUX13_DTSI[fam]), QUUX13_DTSI[fam])
        m = re.fullmatch(r"quux13@([0-9a-fA-F]+)", c.get("RESERVED13", ""))
        if not m:
            fail("%s names no REVISION=13 RESERVED=quux13@... node for %s" % (MKSD, NAMES[fam]))
        same("revision 13's reservation", fam, [
            (DDR_MAP + " QUUX13_MAIN_BASE", pm["QUUX13_MAIN_BASE"]),
            (QUUX13_DTSI[fam] + " reg", base),
            (QUUX13_DTSI[fam] + " unit address", unit),
            (MKSD + " REVISION=13 RESERVED", int(m.group(1), 16))])
        same("revision 13's reservation's end", fam, [
            (DDR_MAP + " QUUX13_RESERVED_END", pm["QUUX13_RESERVED_END"]),
            ("the spare's base + RECORDS_BYTES", pm["DISPLAY_BASE"] + pm["DISPLAY_WORDS"] * 4
             + pm["RECORDS_BYTES"]),
            (QUUX13_DTSI[fam] + " reg", base + size)])
        end13 = pm["QUUX13_MAIN_BASE"] + 5 * pm["QUUX13_MAIN_WORDS_MAX"]
        if end13 != pm["DISPLAY_BASE"]:
            disagree("%s: revision 13's main memory, 5 bytes a word, ends at 0x%08X and the "
                     "display begins at 0x%08X" % (NAMES[fam], end13, pm["DISPLAY_BASE"]))
        if pm["QUUX13_MAIN_BASE"] % 4096:
            disagree("%s: revision 13's main memory at 0x%08X is not on a 4 KB boundary "
                     "(G1 4.1)" % (NAMES[fam], pm["QUUX13_MAIN_BASE"]))

    gpo = env_value(read(root, UBOOT_ENV), "cadr_gpo")
    h = header["de25"]
    same("the GPO register", "de25", [
        ("cadr_board.h TALLY_PAGE + TALLY_OFF0 - 4",
         h["TALLY_PAGE"] + h["TALLY_OFF0"] - GPO_BELOW_GPI),
        (UBOOT_ENV + " cadr_gpo", gpo)])

    kr260(root, pkg)

    if problems:
        fail("the copies of a board's memory map disagree in %d place(s)" % len(problems))
    print("mem_map: every copy of the three board families' memory maps agrees")
    if args.stamp:
        os.makedirs(os.path.dirname(args.stamp) or ".", exist_ok=True)
        open(args.stamp, "w").close()


if __name__ == "__main__":
    main()
