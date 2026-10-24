# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""QUUX's figures at a QUUX top level's instances, for the three boards'
param checks (`tools/quux15_<board>_param_check.py`).

**MACHINE-ID AT THE CORE**: `{0x5155, 16, 4}`, revision 16's.  **THE
SPLIT'S SECOND PAGE**: the Ethernet device's, at the pack side's base plus
`quux-ethernet-device`'s own `QED_FACE_OFFSET` (`qed_face.h`, read here),
with `quux_ed_face.sv` behind it carrying the program's IDENT
(`qed_face_fabric.c`'s `QED_IDENT_16`, read here).  **AND ANOTHER REVISION
REFUSED**: the top elaborated with `REVISION` 15 stops with its own words.
"""

import os
import re

from machine_param_check import params_at_cell

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
QED_SRC = os.path.join(ROOT, "boards/arty-z7-20/linux/buildroot/package/quux-ethernet-device/src")


def _define(path, name):
    with open(path) as f:
        m = re.search(r"^#define\s+%s\s+0x([0-9A-Fa-f]+)u?\b" % name, f.read(), re.M)
    if not m:
        raise SystemExit("ethernet_page_check: %s defines no %s" % (path, name))
    return int(m.group(1), 16)


QED_FACE_OFFSET = _define(os.path.join(QED_SRC, "qed_face.h"), "QED_FACE_OFFSET")
QED_IDENT_16 = _define(os.path.join(QED_SRC, "qed_face_fabric.c"), "QED_IDENT_16")


# QUUX's revision, the only one a top builds (QUUX's Ethernet contract, §10).
REVISION = 16


def figures(tree, top, split, at, say):
    """The figures at `top`'s instances, each said."""
    want = (0x5155 << 16) | (REVISION << 4) | 4
    got, why = params_at_cell(tree, top, "u_core", ["MACHINE_ID"])
    what = "%s, u_core: MACHINE-ID %08x, revision %d" % (at, want, REVISION)
    say(got == {"MACHINE_ID": want}, what if got == {"MACHINE_ID": want}
        else "%s --- it elaborates %s" % (what, got or why))
    got, why = params_at_cell(tree, top, split, ["PACK_BASE", "CHAOS_BASE"])
    if got is None:
        say(False, "%s, %s: no pack side's base or second page --- %s" % (at, split, why or "no such cell"))
    else:
        what = "%s, %s: the second page the Ethernet device's, at the pack side's %08x + %04x" % (
            at, split, got["PACK_BASE"], QED_FACE_OFFSET)
        ok = got["CHAOS_BASE"] == got["PACK_BASE"] + QED_FACE_OFFSET
        say(ok, what if ok else "%s --- it is at %08x" % (what, got["CHAOS_BASE"]))
    got, why = params_at_cell(tree, top, "u_ed_face", ["IDENT"])
    what = "%s, u_ed_face: IDENT %08x, the program's" % (at, QED_IDENT_16)
    say(got == {"IDENT": QED_IDENT_16}, what if got == {"IDENT": QED_IDENT_16}
        else "%s --- it elaborates %s" % (what, got or why or "no such cell"))


def refuses_another(run, base, sources, say):
    """`base` (a Verilator command up to its sources) with `REVISION` 15
    must stop, with the top's own words."""
    rc, out = run(base[:1] + ["--lint-only"] + base[1:] + ["-GREVISION=15"] + sources)
    what = "REVISION=15 stops elaboration: this board builds QUUX revision 16"
    ok = rc != 0 and "this board builds QUUX revision 16" in out
    say(ok, what if ok else "%s --- %s" % (what, "it elaborated" if rc == 0 else out.strip()[-400:]))
