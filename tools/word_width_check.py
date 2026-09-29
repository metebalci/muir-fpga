#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Whether the word's width reaches the processor's words.

    python3 tools/word_width_check.py .

`WORD_BITS` is the word's width, muir's `Geometry::word_bits`: 32 on the CADR
and on QUUX to revision 12, 40 on revision 13 (contract G2 §2.1).
`cadr_machine` takes it and hands it to `cadr_microcycle`, which declares its
words with it.  Every check against muir builds the machine at 32, where a
word declared `[31:0]` and a word declared `[WORD_BITS-1:0]` are the same
design; so a word that dropped the parameter, or a machine that did not pass
it down, would leave every one of them green.  This asks the question at 40.

**THE MACHINE LINTS CLEAN AT EACH WIDTH IT TAKES**: the CADR at 32, QUUX at
32 and at 40, `cadr_machine` as the top and Verilator's `-Wall`.  At 40 a
word left at 32 bits is a width Verilator names.

**AND THE WIDTHS ARE READ BACK, NOT INFERRED FROM THE TEXT.**  For each of
the three, Verilator writes its elaborated tree as JSON and this reads the
width of every word in the module `cadr_machine`'s `processor` cell was
elaborated into, and of `cadr_machine`'s own word ports: each must be
`WORD_BITS`.  And the processor's parts that stay 32 bits at 40 (the ALU's
output `ALU<31:0>`, the cables' `MEM<31:0>` both ways and the statistics
counter) must be 32, so that the list of what is still 32 bits in
`cadr_microcycle.sv`'s header is held as well as the list of words.

**AND REVISION 13'S SIZES COME WITH THE WORD** (contract G2, appendix A1):
at 40 the location counter is 30 bits, the level-2 entry and its latch 28,
the level-1 entry 7 and `MAP(MD)` 40; the dispatch memory has 4,096 entries,
level 1 8,192 and level 2 4,096, with their addresses 12, 13 and 12 bits
wide; and at 32 each is revision 12's or the CADR's.  Read back as the
words are, element widths and array depths both.

**A WIDTH THE MACHINE DOES NOT HAVE MUST STOP ELABORATION** with the
processor's own message: 40 on the CADR, and 36 on QUUX.

WHAT THIS DOES NOT SAY.  It says nothing about what a 40-bit word does:
that is revision 13's programs' (`build/quux13_*.quux.k4.pass`), against
muir's traces on `Geometry::QUUX_13`, and at 32 every other check's.

Exit status 0 when every case agrees, 1 otherwise, with each case's line
printed either way.
"""

import json
import os
import subprocess
import sys
import tempfile

VERILATOR = os.environ.get("VERILATOR", "verilator")

PACKAGES = ["rtl/machine/cadr_tick_pkg.sv", "rtl/plumbing/cadr_ddr_map.sv"]
DIRS = ["rtl/machine", "rtl/plumbing", "rtl/plumbing/xilinx7", "boards/arty-z7-20"]
TOP = "rtl/machine/cadr_machine.sv"

# The processor's words, `cadr_microcycle.sv`'s `WORD_BITS`.
WORDS = ["a", "m", "r", "ob", "q", "vma", "md", "l", "mf", "mo", "md_held",
         "md_bus", "vmas", "m31_r", "macro_m31_w", "mmem_out",
         "amem", "mmem", "pdl", "amem_q", "mmem_q", "pdl_q",
         "ro_amem_q", "ro_mmem_q", "ro_pdl_q", "mtag", "alu_tag", "qtag"]
# What stays 32 bits at 40.
NARROW = ["alu", "rdata", "wdata", "st"]
# Revision 13's sizes and revision 12's and the CADR's (A1.4, A1.6, A1.7):
# name -> (CADR, QUUX at 32, QUUX at 40), an element's width.
SIZED = {
    "lc_q": (26, 26, 30), "vmo": (24, 24, 28), "lvmo": (24, 24, 28),
    "vmap": (5, 6, 7), "l1_map": (5, 6, 7), "l2_map": (24, 24, 28),
    "mf_map": (32, 32, 40), "msk": (32, 32, 40),
    "dadr": (11, 11, 12), "adr0": (11, 11, 13), "adr1": (10, 11, 12),
}
# And the arrays' depths.
DEEP = {"dmem": (2048, 2048, 4096), "l1_map": (2048, 2048, 8192), "l2_map": (1024, 2048, 4096)}
# The machine's own ports that carry a word.
MACHINE_WORDS = ["a", "m", "ob", "q", "vma", "md"]

CASES = [("cadr", 32), ("quux", 32), ("quux", 40)]
REFUSED = [("cadr", 40), ("quux", 36)]

log = []
failures = []


def say(ok, what):
    head, _, rest = what.partition("\n")
    log.append("word: %s  %s" % ("ok    " if ok else "FAILED", head))
    log.extend("    | " + line for line in rest.split("\n") if rest)
    if not ok:
        failures.append(head)


def run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def verilator(machine, bits, mode, mdir=None):
    cmd = [VERILATOR, mode]
    if mode == "--lint-only":
        cmd.append("-Wall")
    else:
        # The tree is read whatever lint says, which the lint case says.
        cmd.append("-Wno-fatal")
    cmd += ["-I" + d for d in DIRS]
    cmd += ['-GMACHINE="%s"' % machine, "-GWORD_BITS=%d" % bits]
    if mdir is not None:
        cmd += ["-Mdir", mdir]
    cmd += ["--top-module", "cadr_machine"] + PACKAGES + [TOP]
    return run(cmd)


def quoted(out, n=12):
    lines = [l for l in out.split("\n") if l.startswith("%")]
    return "\n".join(lines[:n])


def width(dtype, by_addr):
    """A packed width, through an unpacked array to its element."""
    while dtype.get("type") == "UNPACKARRAYDTYPE":
        dtype = by_addr[dtype["refDTypep"]]
    rng = dtype.get("range")
    if dtype.get("type") != "BASICDTYPE" or not rng:
        return None
    hi, lo = (int(x) for x in rng.split(":"))
    return abs(hi - lo) + 1


def depth(dtype, by_addr):
    """An unpacked array's number of elements, or None."""
    rng = dtype.get("declRange", "").strip("[]")
    if dtype.get("type") != "UNPACKARRAYDTYPE" or ":" not in rng:
        return None
    hi, lo = (int(x) for x in rng.split(":"))
    return abs(hi - lo) + 1


def widths(tree, depths=None):
    """{module name: {variable: width}} for the module-level variables, and
    their depths into `depths` the same way."""
    by_addr = {}

    def index(n):
        if isinstance(n, dict):
            if "addr" in n:
                by_addr[n["addr"]] = n
            for v in n.values():
                index(v)
        elif isinstance(n, list):
            for v in n:
                index(v)

    index(tree)
    out = {}
    for mod in tree.get("modulesp", []):
        if mod.get("type") != "MODULE":
            continue
        vs = out.setdefault(mod["name"], {})
        ds = depths.setdefault(mod["name"], {}) if depths is not None else {}
        for st in mod.get("stmtsp", []):
            if st.get("type") == "VAR":
                vs[st["name"]] = width(by_addr[st["dtypep"]], by_addr)
                ds[st["name"]] = depth(by_addr[st["dtypep"]], by_addr)
    return out


def read_back(machine, bits, scratch):
    mdir = os.path.join(scratch, "%s_%d" % (machine, bits))
    rc, out = verilator(machine, bits, "--json-only", mdir)
    if rc != 0:
        say(False, "%s at %d: Verilator did not write its tree\n%s" % (machine, bits, quoted(out)))
        return
    deep = {}
    with open(os.path.join(mdir, "Vcadr_machine.tree.json")) as f:
        mods = widths(json.load(f), deep)
    procs = [name for name in mods if name.startswith("cadr_microcycle")]
    if len(procs) != 1:
        say(False, "%s at %d: %d processors elaborated, want one: %s" % (machine, bits, len(procs), procs))
        return
    proc = mods[procs[0]]
    wrong = []
    for name in WORDS:
        if proc.get(name) != bits:
            wrong.append("processor %s is %s bits" % (name, proc.get(name)))
    for name in NARROW:
        if proc.get(name) != 32:
            wrong.append("processor %s is %s bits, want 32" % (name, proc.get(name)))
    top = mods.get("cadr_machine", {})
    for name in MACHINE_WORDS:
        if top.get(name) != bits:
            wrong.append("cadr_machine %s is %s bits" % (name, top.get(name)))
    which = CASES.index((machine, bits))
    for name, want in sorted(SIZED.items()):
        if proc.get(name) != want[which]:
            wrong.append("processor %s is %s bits, want %d" % (name, proc.get(name), want[which]))
    pdeep = deep[procs[0]]
    for name, want in sorted(DEEP.items()):
        if pdeep.get(name) != want[which]:
            wrong.append("processor %s has %s entries, want %d" % (name, pdeep.get(name), want[which]))
    say(not wrong, "%s at %d: %d words of %d bits, %d parts of 32, %d ports of the machine, "
        "%d sizes and %d depths of the revision%s"
        % (machine, bits, len(WORDS), bits, len(NARROW), len(MACHINE_WORDS), len(SIZED), len(DEEP),
           "" if not wrong else "\n" + "\n".join(wrong)))


def main():
    os.chdir(sys.argv[1] if len(sys.argv) > 1 else ".")
    with tempfile.TemporaryDirectory(prefix="word_width_") as scratch:
        for machine, bits in CASES:
            rc, out = verilator(machine, bits, "--lint-only")
            say(rc == 0, "%s at %d lints clean with -Wall%s"
                % (machine, bits, "" if rc == 0 else "\n" + quoted(out)))
            read_back(machine, bits, scratch)
        for machine, bits in REFUSED:
            rc, out = verilator(machine, bits, "--lint-only")
            want = "cadr_microcycle: WORD_BITS is %d on %s" % (bits, machine)
            ok = rc != 0 and want in out
            say(ok, "%s at %d is refused by the processor" % (machine, bits)
                + ("" if ok else "\n" + quoted(out)))
    print("\n".join(log))
    if failures:
        print("word: %d of the cases above FAILED" % len(failures))
        return 1
    print("word: ok, the width reaches every word at 32 and 40")
    return 0


if __name__ == "__main__":
    sys.exit(main())
