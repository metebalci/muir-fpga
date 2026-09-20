#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The DE25-Nano's register faces sit where the programs look for them.

WHY THIS EXISTS.  The faces behind a processor-to-fabric bridge are placed by
parameters on the instances in `boards/de25-nano/cadr_de25.sv`, and that file
cannot be simulated: it instantiates a generated processor system, so lint and
the fitter are all that read it.  Lint holds that every port is connected and
has nothing whatever to say about a number.  A face placed one page out
therefore builds, fits and programs, and is found only when a program reads
`0x4000_1000` and gets the word the default slave answers with -- or, worse,
the word of the face next door, which looks like a working face with wrong
contents.

WHAT MAKES IT CHECKABLE IS THAT THE ADDRESS IS WRITTEN TWICE.  A program takes
its address from `cadr_board.h`, which names the PROCESSOR's address; the
fabric takes its from the instance, which is an OFFSET into the bridge's own
window, because these bridges hand the fabric an offset and not the
processor's address.  The two are the same fact seen from the two ends of the
bridge, so they can be required to agree:

    the face's parameter  ==  the program's address  -  the bridge's window

and the windows are the Agilex 5 HPS Technical Reference Manual's (document
814346, Table 322): the lightweight bridge's 512 MB at 0x2000_0000 and the
HPS-to-FPGA bridge's 1 GB at 0x4000_0000.  Those two numbers are this file's
own, from the manual, and everything else is read out of the tree.

AND THE SHAPE, which is the other thing a parameter decides here.  Both
bridges are AXI4: four bits of transaction ID where a Zynq general-purpose
port has twelve, and eight bits of burst length where AXI3 has four.  Every
face on them is built with those two widths, and a face left at the defaults
would answer a 256-beat read with sixteen beats and leave the processor
waiting for the rest -- which on a general-purpose port is not a wrong answer
but two frozen cores.  So each instance is required to carry both.

It writes its stamp and prints what it found.  Run as

    python3 tools/de25_faces_check.py . --stamp build/de25_faces.pass
"""

import argparse
import os
import re
import sys

# The two windows, from the manual.  Written here because they are facts about
# the part and not about this design, and everything else is read from the
# tree.
H2F_BASE = 0x40000000
H2F_SIZE = 1024 * 1024 * 1024
LW_BASE = 0x20000000
LW_SIZE = 512 * 1024 * 1024

TOP = "boards/de25-nano/cadr_de25.sv"
BOARD_H = ("boards/arty-z7-20/linux/buildroot/package/cadr-common/src/cadr/"
           "cadr_board.h")

# Each face: the instance in the top level, the parameter that places it, the
# bridge it is on, and the name `cadr_board.h` gives the program's address.
# The debug cable's window has no program address of its own -- muir is given
# it on its command line -- so it is held one page above the console, which is
# what the header and `cadr_gp1_split.sv` both say.
FACES = [
    ("u_h2f_split", "PACK_BASE", "h2f", "PACK"),
    ("u_h2f_split", "CHAOS_BASE", "h2f", "CHAOS"),
    ("u_h2f_split", "SER_BASE", "h2f", "SERIAL"),
    ("u_h2f_split", "INPUT_BASE", "h2f", "INPUT"),
    ("u_pack", "REG_BASE", "h2f", "PACK"),
    ("u_lw_split", "CON_BASE", "lw", "CONSOLE"),
    ("u_lw_split", "DBG_BASE", "lw", "CONSOLE+0x1000"),
    ("u_console", "REG_BASE", "lw", "CONSOLE"),
    ("u_debug_window", "REG_BASE", "lw", "CONSOLE+0x1000"),
]

# Every instance on either bridge takes the bridges' AXI4 widths.
SHAPED = ["u_h2f_split", "u_pack", "u_chaos", "u_serial", "u_input",
          "u_h2f_rest", "u_lw_split", "u_console", "u_debug_window",
          "u_lw_rest"]

WINDOWS = {"h2f": (H2F_BASE, H2F_SIZE), "lw": (LW_BASE, LW_SIZE)}


def fail(msg):
    print("de25_faces: " + msg, file=sys.stderr)
    sys.exit(1)


def instance_parameters(text, instance):
    """The parameter overrides on one instance, as {name: int}.

    The instance is `<module> #( ... ) <instance> (`, and what is wanted is
    the parameter list between them.  A module with no overrides at all is an
    instance with no `#(`, which this reports as an empty map rather than as
    an error: the caller says which parameters it wanted.
    """
    m = re.search(r"\b(\w+)\s*#\(([^;]*?)\)\s*" + re.escape(instance) + r"\s*\(",
                  text, re.S)
    if not m:
        if re.search(r"\b(\w+)\s+" + re.escape(instance) + r"\s*\(", text):
            return {}
        fail("no instance named `%s` in %s" % (instance, TOP))
    out = {}
    for name, value in re.findall(r"\.(\w+)\s*\(\s*([^()]*?)\s*\)", m.group(2)):
        v = value.replace("_", "").strip()
        n = re.match(r"^(?:\d+)'h([0-9a-fA-F]+)$", v)
        if n:
            out[name] = int(n.group(1), 16)
            continue
        n = re.match(r"^(?:(?:\d+)'d)?(\d+)$", v)
        if n:
            out[name] = int(n.group(1))
    return out


def board_addresses(text):
    """The DE25-Nano's addresses out of `cadr_board.h`.

    The file holds one block per board, and the DE25-Nano's is the one under
    `#if defined(CADR_BOARD_DE25_NANO)`.  Taking the whole file would read the
    Zynq's numbers as well, and those are a different board's.
    """
    start = text.index("#if defined(CADR_BOARD_DE25_NANO)")
    end = text.index("#else", start)
    out = {}
    for name, hexdigits in re.findall(
            r"#define\s+CADR_BOARD_(\w+)_HEX\s+([0-9A-Fa-f]+)",
            text[start:end]):
        out[name] = int(hexdigits, 16)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("root", help="the repository's root")
    ap.add_argument("--stamp", help="write this file when the check passes")
    args = ap.parse_args()

    top_path = os.path.join(args.root, TOP)
    board_path = os.path.join(args.root, BOARD_H)
    for p in (top_path, board_path):
        if not os.path.exists(p):
            fail("%s is not there" % p)
    top = open(top_path).read()
    board = board_addresses(open(board_path).read())

    bad = 0
    print("de25_faces: the bridges' windows are 0x%08X for %d MB and "
          "0x%08X for %d MB" %
          (LW_BASE, LW_SIZE >> 20, H2F_BASE, H2F_SIZE >> 20))

    for instance, param, bridge, addr_name in FACES:
        params = instance_parameters(top, instance)
        if param not in params:
            fail("%s does not set `%s`, so its face is wherever the module's "
                 "own default puts it" % (instance, param))
        base, size = WINDOWS[bridge]
        key = addr_name
        plus = 0
        if "+" in addr_name:
            key, extra = addr_name.split("+")
            plus = int(extra, 16)
        if key not in board:
            fail("cadr_board.h names no CADR_BOARD_%s_HEX for this board" % key)
        want = board[key] + plus - base
        got = params[param]
        if got != want:
            print("de25_faces: %s.%s is 0x%08X, and the programs look at "
                  "0x%08X, which is 0x%08X into the bridge's window at "
                  "0x%08X" % (instance, param, got, board[key] + plus, want,
                              base), file=sys.stderr)
            bad += 1
            continue
        if got + 0x1000 > size:
            print("de25_faces: %s.%s is 0x%08X, which is outside the bridge's "
                  "%d MB window" % (instance, param, got, size >> 20),
                  file=sys.stderr)
            bad += 1
            continue
        print("de25_faces: %-15s %-11s 0x%08X   the programs' 0x%08X" %
              (instance, param, got, board[key] + plus))

    for instance in SHAPED:
        params = instance_parameters(top, instance)
        for name, want in (("ID_W", 4), ("LEN_W", 8)):
            if params.get(name) != want:
                print("de25_faces: %s does not set %s to %d, so it is built "
                      "at the Zynq's AXI3 shape on an AXI4 bridge" %
                      (instance, name, want), file=sys.stderr)
                bad += 1
    if bad == 0:
        print("de25_faces: all %d instances carry the bridges' four bits of "
              "ID and eight of burst length" % len(SHAPED))

    if bad:
        fail("%d of the DE25-Nano's faces are not where the programs look for "
             "them, or are not the bridges' shape" % bad)

    print("de25_faces: %d faces, each at the offset its program's address is "
          "into its bridge's window" % len(FACES))
    if args.stamp:
        os.makedirs(os.path.dirname(args.stamp), exist_ok=True)
        open(args.stamp, "w").close()


if __name__ == "__main__":
    main()
