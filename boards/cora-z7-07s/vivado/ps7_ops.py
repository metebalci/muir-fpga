# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What the Cora Z7-07S's `ps7_init` actually writes, as an ordered list, so
# that it can be checked.
#
#     python3 boards/cora-z7-07s/vivado/ps7_ops.py          # regenerate the .ops
#     python3 boards/cora-z7-07s/vivado/ps7_ops.py --check  # is it current?
#     python3 boards/cora-z7-07s/vivado/ps7_ops.py --from F # extract from a routine
#
# THIS IS A FRONT END AND NOT A SECOND EXTRACTOR, on the same argument as
# `boards/cora-z7-07s/vivado/gen_ps7.py`: it loads
# `boards/arty-z7-20/vivado/ps7_ops.py` as a module and points that file's own
# extraction at this board's generator and this board's committed `.ops`. The
# extraction itself --- which verbs count as a register operation, how
# `mwr -force` is rewritten, the landmark writes that say the parse found real
# ones, and the self-test behind all of it --- is hard-won and there is one
# copy of it.
#
# WHAT DIFFERS IS TWO PATHS AND THE HEADER THE GENERATED FILE CARRIES. The
# committed file is `boards/cora-z7-07s/vivado/ps7_init.ops` and the routine
# comes from `boards/cora-z7-07s/vivado/gen_ps7_init.tcl`, which reads this
# board's `ps7_config.tcl`.
#
# **AND THERE IS NO INDEPENDENT CONTROL FOR THIS BOARD, WHERE THE ARTY Z7-20
# HAS ONE.** That board's routine is compared op for op against the one in
# Digilent's own PetaLinux BSP for it --- a different tool eight releases
# apart, agreeing character for character on every DDR, PLL, MIO and
# post-config write. No such artefact was found for the Cora Z7-07S:
# `github.com/Digilent/Cora-Z7-HW`'s per-board branches are empty root
# commits. So what holds this file is the provenance of
# `boards/cora-z7-07s/vivado/ps7_config.tcl` --- Digilent's own maintained
# board preset, by sha256 --- and the fact that the .ops moves when the
# configuration moves. That is weaker and is stated rather than glossed.
#
# WITHOUT VIVADO IT SKIPS AND SAYS SO, as the Arty's does.

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
ARTY = os.path.join(REPO, "boards", "arty-z7-20", "vivado", "ps7_ops.py")

# The Arty's paths, and this board's, in the header the generated file carries
# and in the two globals that say where to read and write. Each replacement is
# asserted, so a reworded header upstream stops this rather than leaving a
# generated file that points at the other board.
RELABEL = [
    ("boards/arty-z7-20/vivado/ps7_ops.py",
     "boards/cora-z7-07s/vivado/ps7_ops.py"),
    ("boards/arty-z7-20/vivado/gen_ps7_init.tcl",
     "boards/cora-z7-07s/vivado/gen_ps7_init.tcl"),
    ("boards/arty-z7-20/vivado/ps7_config.tcl",
     "boards/cora-z7-07s/vivado/ps7_config.tcl"),
    ("run `make ps7-init`", "run `make ps7-init-cora`"),
]

# And two more for what the shared `main()` PRINTS, which names the committed
# file the generated header does not. Kept apart from the list above because
# each entry there is asserted to appear in the generated header, and these
# two do not.
SAID = RELABEL + [
    ("boards/arty-z7-20/vivado/ps7_init.ops",
     "boards/cora-z7-07s/vivado/ps7_init.ops"),
    ("`make ps7-init`", "`make ps7-init-cora`"),
]


def die(msg):
    sys.stderr.write("ps7_ops-cora: %s\n" % msg)
    sys.exit(1)


def main():
    spec = importlib.util.spec_from_file_location("cadr_ps7_ops_arty", ARTY)
    if spec is None or spec.loader is None:
        die("%s cannot be loaded" % os.path.relpath(ARTY, REPO))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    mod.OPS = os.path.join(HERE, "ps7_init.ops")
    mod.GEN = os.path.join("boards", "cora-z7-07s", "vivado",
                           "gen_ps7_init.tcl")
    # A directory of this board's own, so that a run here cannot overwrite the
    # routine the other board's run left behind and be compared against it.
    mod.OUTDIR = os.path.join("build", "ps7-cora")

    inner = mod.rendered

    def rendered(ops):
        text = inner(ops)
        for old, new in RELABEL:
            if text.count(old) < 1:
                die("the generated header no longer names %s; read %s's "
                    "`rendered()` and settle it there"
                    % (old, os.path.relpath(ARTY, REPO)))
            text = text.replace(old, new)
        return text

    mod.rendered = rendered

    # **AND WHAT IT SAYS ON THE WAY OUT IS RELABELLED TOO.**  The shared
    # `main()` writes the other board's path into its own success and failure
    # messages as literal text, so a run here would report that the ARTY's
    # `.ops` is current while having read and written this board's.  A message
    # that names the wrong file is the shape of failure this repository spends
    # its prose on, so the output is passed through the same relabelling the
    # generated file gets.  `--check` reads the committed file through
    # `committed()`, which closes over the module's own `OPS`; overriding the
    # global is enough because nothing captured the old value.
    class Relabel(object):
        def __init__(self, out):
            self.out = out

        def write(self, text):
            for was, now in SAID:
                text = text.replace(was, now)
            return self.out.write(text)

        def flush(self):
            self.out.flush()

    out, err = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = Relabel(out), Relabel(err)
    try:
        return mod.main()
    finally:
        sys.stdout, sys.stderr = out, err


if __name__ == "__main__":
    sys.exit(main())
