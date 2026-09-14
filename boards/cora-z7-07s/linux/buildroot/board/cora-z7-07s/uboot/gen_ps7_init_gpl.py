#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The Cora Z7-07S's Zynq start-up routine, as the C table U-Boot's SPL runs.
#
#     python3 gen_ps7_init_gpl.py              # rewrite ps7_init_gpl.c beside this file
#     python3 gen_ps7_init_gpl.py --check      # is the committed one what the .ops say?
#     python3 gen_ps7_init_gpl.py --compare F  # same operations as a ps7_init_gpl.c
#                                              # Vivado (or U-Boot) wrote?
#
# THIS IS A FRONT END AND NOT A SECOND GENERATOR, on the same argument as
# `boards/cora-z7-07s/vivado/gen_ps7.py` and `.../ps7_ops.py`: it loads the
# Arty Z7-20's generator as a module and points that file's own emitter at
# this board's `.ops` and this board's output. The encoding U-Boot's
# `ps7_spl_init.c` expects, what is left out of the table and why, and the
# `--compare` parser that reads both Vivado's encoding and U-Boot's are
# hard-won and there is one copy of them.
#
# WHAT DIFFERS IS TWO PATHS AND THE HEADER THE GENERATED FILE CARRIES:
# `boards/cora-z7-07s/vivado/ps7_init.ops` in and `ps7_init_gpl.c` beside this
# file out.

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", "..", "..",
                                    ".."))
ARTY = os.path.join(REPO, "boards", "arty-z7-20", "linux", "buildroot",
                    "board", "arty-z7-20", "uboot", "gen_ps7_init_gpl.py")

# The Arty's paths, and this board's, in the header the generated file
# carries. Each is asserted, so a reworded header upstream stops this rather
# than leaving a generated file that points at the other board's data.
RELABEL = [
    ("The Arty Z7-20's Zynq start-up routine",
     "The Cora Z7-07S's Zynq start-up routine"),
    ("boards/arty-z7-20/vivado/ps7_init.ops",
     "boards/cora-z7-07s/vivado/ps7_init.ops"),
    ("boards/arty-z7-20/linux/buildroot/board/arty-z7-20/uboot/"
     "gen_ps7_init_gpl.py",
     "boards/cora-z7-07s/linux/buildroot/board/cora-z7-07s/uboot/"
     "gen_ps7_init_gpl.py"),
]


def die(msg):
    sys.stderr.write("ps7_init_gpl-cora: %s\n" % msg)
    sys.exit(1)


def main():
    if not os.path.exists(ARTY):
        die("%s is not here" % ARTY)
    spec = importlib.util.spec_from_file_location("cadr_gen_gpl_arty", ARTY)
    if spec is None or spec.loader is None:
        die("%s cannot be loaded" % ARTY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    mod.OPS = os.path.join(REPO, "boards", "cora-z7-07s", "vivado",
                           "ps7_init.ops")
    mod.OUT = os.path.join(HERE, "ps7_init_gpl.c")

    # **THE EXTRA PROC THIS BOARD's ROUTINE HAS, AND WHERE IT GOES.**  Vivado
    # writes a `ps7_apu_reset` for a single-core part and calls it from
    # `ps7_init()` BEFORE the silicon-version dispatch: one `mask_write` to
    # SLCR `A9_CPU_RST_CTRL` at 0xF8000244, mask and value 0x00000022, which
    # is Xilinx's own file's name for that register
    # ($XILINX_VIVADO/data/PS/7series/data/zynqconfig/ps7regs/sw_regs.xml,
    # "CPU Reset and Clock control").  The Arty Z7-20's routine has no such
    # proc, that part having two cores, so the shared generator knows nothing
    # about it and its table regex would refuse the name.
    #
    # **IT IS FOLDED ONTO THE FRONT OF EACH VERSION's MIO TABLE RATHER THAN
    # SKIPPED**, because `mio_init_data` is the first of `INIT_STAGES` and so
    # runs first in `ps7_init()` --- the same operation at the same point in
    # the same order as Vivado's own routine puts it.  Skipping it was the
    # other option and is rejected: a register write the vendor's routine
    # performs on this part is not ours to leave out on the argument that
    # U-Boot's SPL happens never to start a second core.
    #
    # The operation is asserted rather than trusted: if the routine ever
    # carries a different one under that name, this stops.
    APU_RESET = "ps7_apu_reset"
    WANT = ("mask_write", 0xF8000244, 0x00000022, 0x00000022)

    read_ops_inner = mod.read_ops

    def read_ops(path):
        # The line is found in the file itself, because the shared parser
        # refuses a proc it cannot place and would stop before this could
        # look. Then the proc is added to that parser's skip list so it reads
        # the rest unchanged, and the operation is put back below.
        found = [l.split() for l in open(path)
                 if l.split() and l.split()[0] == APU_RESET]
        if len(found) != 1:
            die("%s carries %d line(s) of %s, wanting one --- this front end "
                "folds that proc into the MIO tables"
                % (path, len(found), APU_RESET))
        word = found[0]
        if len(word) != 5 or word[1] != "mask_write":
            die("%s is %r, wanting one mask_write" % (APU_RESET, word))
        apu = [("write" if int(word[3], 0) == mod.FULL else "mask_write",
                int(word[2], 0), int(word[3], 0), int(word[4], 0))]
        if apu[0] != WANT:
            die("%s is %r, wanting %r --- read it before folding it in"
                % (APU_RESET, apu[0], WANT))
        mod.SKIPPED = __import__("re").compile(
            mod.SKIPPED.pattern[:-2] + "|" + APU_RESET + ")$")
        tables, order = read_ops_inner(path)
        folded = 0
        for name in list(tables):
            if name.startswith("ps7_mio_init_data_"):
                tables[name] = apu + tables[name]
                folded += 1
        if folded != 3:
            die("folded %s into %d MIO table(s), wanting three --- one per "
                "silicon revision" % (APU_RESET, folded))
        return tables, order

    mod.read_ops = read_ops

    inner = mod.render

    def render(tables):
        text, count, ntables = inner(tables)
        for old, new in RELABEL:
            if text.count(old) != 1:
                die("the generated header names %s %d time(s), wanting one; "
                    "read the Arty's `render()` and settle it there"
                    % (old, text.count(old)))
            text = text.replace(old, new)
        return text, count, ntables

    mod.render = render
    return mod.main()


if __name__ == "__main__":
    sys.exit(main())
