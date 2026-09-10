#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The Zynq start-up routine, as the C table U-Boot's SPL runs.
#
#     python3 gen_ps7_init_gpl.py              # rewrite ps7_init_gpl.c beside this file
#     python3 gen_ps7_init_gpl.py --check      # is the committed one what the .ops say?
#     python3 gen_ps7_init_gpl.py --compare F  # same operations as a ps7_init_gpl.c
#                                              # Vivado (or U-Boot) wrote?
#
# WHERE THE DATA COMES FROM, AND WHY FROM THERE.  vivado/ps7_init.ops is the
# committed claim about what the board's first-stage loader must write:
# every register operation of Digilent's routine, in order, extracted by
# vivado/ps7_ops.py from the ps7_init.tcl that vivado/gen_ps7_init.tcl
# generates, and held current by `make current`.  The same IP flow also
# writes a ps7_init_gpl.c (build/ps7/, not committed), and that file could
# have been copied here instead.  It is not, for two reasons:
#
#   - a checkout without Vivado --- CI, or anyone else --- can then build the
#     loader from the repository alone, because the .ops file is in it;
#   - Vivado's C carries its own interpreter (ps7_config, mask_write,
#     ps7GetSiliconVersion, the SCU timer helpers) and its own opcode
#     encoding, and U-Boot has all of that already in
#     arch/arm/mach-zynq/ps7_spl_init.c with a different encoding
#     (arch/arm/mach-zynq/include/mach/ps7_init_gpl.h: the opcode in the low
#     two bits of the address).  The in-tree boards under
#     board/xilinx/zynq/<board>/ps7_init_gpl.c are written that way, and so
#     is this one: data tables, ps7_init(), ps7_post_config(), nothing else.
#
# THE TWO ARE PROVED TO AGREE, NOT ASSUMED TO.  `--compare` extracts the
# EMIT_* operations of any ps7_init_gpl.c --- Vivado's encoding or U-Boot's,
# the parser reads both --- normalises them to (register, mask, value) with
# EMIT_WRITE as a full-mask write, and requires the same tables to hold the
# same operations in the same order.  Measured against build/ps7/ps7_init_gpl.c
# at the commit that added this file: identical, 660 operations in 18 tables.
#
# WHAT IS LEFT OUT, AND WHY.  The .ops file carries three things this table
# does not: the `ps7_debug_*` procs (three writes each, run by nothing ---
# Vivado's own C defines ps7_debug() and never calls it), and the
# `perf_start_clock`/`perf_reset_clock`/`perf_disable_clock` helpers, which
# are the SCU global timer the routine uses for mask_delay and which U-Boot
# implements itself in ps7_spl_init.c.  Everything else --- 660 of the 673
# operations --- is here.  The ten procs U-Boot runs are the ten
# `ps7_init` and `ps7_post_config` run in the .tcl, in the same order:
# mio, pll, clock, ddr, peripherals; then post_config.
#
# FULL-MASK WRITES ARE EMIT_WRITE.  The .ops file writes `mwr -force` as a
# mask_write with mask 0xFFFFFFFF, because that is what it is; going back to
# C, every full-mask write becomes EMIT_WRITE, whether Vivado had it as
# EMIT_WRITE or as EMIT_MASKWRITE with a full mask.  The effect is the same
# --- with every bit in the mask the read-back is discarded entirely --- and
# the only difference is a read that no longer happens, which is the safe
# direction for a register whose read might have a side effect.
#
# THE SILICON VERSION DISPATCH IS VIVADO'S.  ps7GetSiliconVersion() is
# U-Boot's zynq_get_silicon_version(), MCTRL[31:28]; 0 and 1 take the 1.0
# and 2.0 tables, everything else --- including this board's 3.1, which
# reads 3 --- takes the 3.0 tables through the `else`, exactly as Vivado's C
# and .tcl do.  CLAUDE.md records that the else branch is the intended path.

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", ".."))
OPS = os.path.join(REPO, "vivado", "ps7_init.ops")
OUT = os.path.join(HERE, "ps7_init_gpl.c")

# The tables U-Boot runs, in the order ps7_init() and ps7_post_config() run
# them --- which is the order the .tcl's own procs of those names run them.
INIT_STAGES = ("mio_init_data", "pll_init_data", "clock_init_data",
               "ddr_init_data", "peripherals_init_data")
POST_STAGE = "post_config"
VERSIONS = ("1_0", "2_0", "3_0")

# Procs in the .ops that are not tables of the routine.  Named, so that a new
# proc appearing in the .ops is an error here and not a silent omission.
SKIPPED = re.compile(r"^(ps7_debug_[123]_0|perf_start_clock|perf_reset_clock"
                     r"|perf_disable_clock)$")
TABLE = re.compile(r"^ps7_(mio_init_data|pll_init_data|clock_init_data"
                   r"|ddr_init_data|peripherals_init_data|post_config)"
                   r"_([123]_0)$")

FULL = 0xFFFFFFFF


def die(msg):
    sys.stderr.write("gen_ps7_init_gpl: %s\n" % msg)
    sys.exit(1)


def read_ops(path):
    """The .ops file as {table: [(verb, addr, mask, value)]}, in file order.

    Every operation is normalised to the same four fields: a mask_poll and a
    mask_delay have no value and carry None there; a full-mask write is a
    write.
    """
    tables = {}
    order = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            word = s.split()
            proc, verb, arg = word[0], word[1], [int(a, 0) for a in word[2:]]
            if SKIPPED.match(proc):
                continue
            if not TABLE.match(proc):
                die("%s:%d: proc %s is neither a table nor known to be "
                    "skippable" % (path, n, proc))
            if verb == "mask_write":
                if len(arg) != 3:
                    die("%s:%d: mask_write wants three arguments" % (path, n))
                op = ("write" if arg[1] == FULL else "mask_write",
                      arg[0], arg[1], arg[2])
            elif verb in ("mask_poll", "mask_delay"):
                if len(arg) != 2:
                    die("%s:%d: %s wants two arguments" % (path, n, verb))
                op = (verb, arg[0], arg[1], None)
            else:
                die("%s:%d: verb %s is not one this generator knows"
                    % (path, n, verb))
            if proc not in tables:
                tables[proc] = []
                order.append(proc)
            tables[proc].append(op)
    want = ["ps7_%s_%s" % (s, v) for v in VERSIONS
            for s in INIT_STAGES + (POST_STAGE,)]
    missing = [t for t in want if t not in tables]
    if missing:
        die("%s: no operations for %s" % (path, ", ".join(missing)))
    extra = [t for t in order if t not in want]
    if extra:
        die("%s: tables this generator does not place: %s"
            % (path, ", ".join(extra)))
    return tables, order


def emit(op):
    verb, addr, mask, val = op
    if verb == "write":
        return "\tEMIT_WRITE(0x%08X, 0x%08XU)," % (addr, val)
    if verb == "mask_write":
        return "\tEMIT_MASKWRITE(0x%08X, 0x%08XU, 0x%08XU)," % (addr, mask, val)
    if verb == "mask_poll":
        return "\tEMIT_MASKPOLL(0x%08X, 0x%08XU)," % (addr, mask)
    if verb == "mask_delay":
        return "\tEMIT_MASKDELAY(0x%08X, 0x%08XU)," % (addr, mask)
    raise AssertionError(verb)


HEADER = """\
// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * The Arty Z7-20's Zynq start-up routine, for U-Boot's SPL.
 *
 * GENERATED by linux/buildroot/board/arty-z7-20/uboot/gen_ps7_init_gpl.py
 * from vivado/ps7_init.ops.  Do not edit; run the generator.  Its header
 * says where the operations come from, what was left out and why, and how
 * this file was proved to agree with the ps7_init_gpl.c Vivado writes.
 *
 * GPL-2.0-or-later rather than the repository's AGPL-3.0-or-later because
 * this file is compiled into U-Boot's SPL, which is GPL-2.0-or-later, and
 * because the tables are Digilent's board configuration as written out by
 * Xilinx's tool, whose own ps7_init_gpl.c carries that licence.
 *
 * The data is what a first-stage loader must write before DDR answers:
 * the pin multiplexing, the three PLLs, the clock tree, the memory
 * controller and its training, the peripheral resets; then, after the
 * fabric is configured, the PS-PL level shifters and the fabric resets.
 * ps7_init() runs the first five tables for this silicon, in the order
 * the .tcl runs them; ps7_post_config() runs the sixth.
 *
 * %d operations in %d tables.
 */

#include <asm/arch/ps7_init_gpl.h>
"""

DISPATCH = """
int ps7_post_config(void)
{
	unsigned long si_ver = ps7GetSiliconVersion();

	if (si_ver == PCW_SILICON_VERSION_1)
		return ps7_config(ps7_post_config_1_0);
	if (si_ver == PCW_SILICON_VERSION_2)
		return ps7_config(ps7_post_config_2_0);
	return ps7_config(ps7_post_config_3_0);
}

static int ps7_init_version(unsigned long *mio, unsigned long *pll,
			    unsigned long *clock, unsigned long *ddr,
			    unsigned long *peripherals)
{
	int ret;

	ret = ps7_config(mio);
	if (ret != PS7_INIT_SUCCESS)
		return ret;
	ret = ps7_config(pll);
	if (ret != PS7_INIT_SUCCESS)
		return ret;
	ret = ps7_config(clock);
	if (ret != PS7_INIT_SUCCESS)
		return ret;
	ret = ps7_config(ddr);
	if (ret != PS7_INIT_SUCCESS)
		return ret;
	return ps7_config(peripherals);
}

int ps7_init(void)
{
	unsigned long si_ver = ps7GetSiliconVersion();

	if (si_ver == PCW_SILICON_VERSION_1)
		return ps7_init_version(ps7_mio_init_data_1_0,
					ps7_pll_init_data_1_0,
					ps7_clock_init_data_1_0,
					ps7_ddr_init_data_1_0,
					ps7_peripherals_init_data_1_0);
	if (si_ver == PCW_SILICON_VERSION_2)
		return ps7_init_version(ps7_mio_init_data_2_0,
					ps7_pll_init_data_2_0,
					ps7_clock_init_data_2_0,
					ps7_ddr_init_data_2_0,
					ps7_peripherals_init_data_2_0);
	return ps7_init_version(ps7_mio_init_data_3_0,
				ps7_pll_init_data_3_0,
				ps7_clock_init_data_3_0,
				ps7_ddr_init_data_3_0,
				ps7_peripherals_init_data_3_0);
}
"""


def render(tables):
    out = []
    count = 0
    names = []
    for v in VERSIONS:
        for stage in INIT_STAGES + (POST_STAGE,):
            name = "ps7_%s_%s" % (stage, v)
            names.append(name)
            out.append("\nstatic unsigned long %s[] = {" % name)
            for op in tables[name]:
                out.append(emit(op))
                count += 1
            out.append("\tEMIT_EXIT(),")
            out.append("};")
    text = HEADER % (count, len(names)) + "\n".join(out) + "\n" + DISPATCH
    return text, count, len(names)


# --- reading a ps7_init_gpl.c back, in either encoding -----------------------

EMIT_RE = re.compile(r"^\s*EMIT_(WRITE|MASKWRITE|MASKPOLL|MASKDELAY|EXIT)\s*\("
                     r"\s*([^)]*)\)\s*,?\s*$")
ARRAY_RE = re.compile(r"^\s*(?:static\s+)?unsigned\s+long\s+(\w+)\s*\[\]\s*=")


def read_c(path):
    """{table: [(verb, addr, mask, value)]} out of a ps7_init_gpl.c.

    Vivado's and U-Boot's files differ in the header they include, in the
    interpreter Vivado's carries, and in whether the tables are static; the
    EMIT_* lines are the same vocabulary in both, and that is all this reads.
    """
    tables = {}
    cur = None
    with open(path) as f:
        for line in f:
            m = ARRAY_RE.match(line)
            if m:
                cur = m.group(1)
                tables[cur] = []
                continue
            if cur is None:
                continue
            m = EMIT_RE.match(line)
            if not m:
                if line.strip().startswith("};"):
                    cur = None
                continue
            verb, args = m.group(1), m.group(2)
            arg = [int(a.strip().rstrip("uU"), 0)
                   for a in args.split(",") if a.strip()]
            if verb == "EXIT":
                cur = None
            elif verb == "WRITE":
                tables[cur].append(("write", arg[0], FULL, arg[1]))
            elif verb == "MASKWRITE":
                kind = "write" if arg[1] == FULL else "mask_write"
                tables[cur].append((kind, arg[0], arg[1], arg[2]))
            elif verb == "MASKPOLL":
                tables[cur].append(("mask_poll", arg[0], arg[1], None))
            elif verb == "MASKDELAY":
                tables[cur].append(("mask_delay", arg[0], arg[1], None))
    return {k: v for k, v in tables.items() if v}


def fmt(op):
    verb, addr, mask, val = op
    return "%s 0x%08X 0x%08X%s" % (verb, addr, mask,
                                   "" if val is None else " 0x%08X" % val)


def compare(ours, theirs, label):
    """Same tables, same operations, same order; say which register if not."""
    bad = 0
    want = sorted(t for t in ours)
    for t in want:
        if t not in theirs:
            sys.stderr.write("gen_ps7_init_gpl: %s has no table %s\n"
                             % (label, t))
            bad += 1
            continue
        a, b = ours[t], theirs[t]
        if a == b:
            continue
        bad += 1
        n = min(len(a), len(b))
        for i in range(n):
            if a[i] != b[i]:
                sys.stderr.write(
                    "gen_ps7_init_gpl: %s[%d]: ours %s, %s %s\n"
                    % (t, i, fmt(a[i]), label, fmt(b[i])))
                break
        else:
            sys.stderr.write("gen_ps7_init_gpl: %s: %d operations here, %d "
                             "in %s\n" % (t, len(a), len(b), label))
    ignored = sorted(t for t in theirs if t not in ours)
    return bad, ignored


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="compare the committed C with what the .ops give")
    ap.add_argument("--compare", metavar="PS7_INIT_GPL_C",
                    help="compare the .ops with the operations in this C file")
    args = ap.parse_args()

    tables, _ = read_ops(OPS)
    text, count, ntables = render(tables)

    if args.compare:
        theirs = read_c(args.compare)
        if not theirs:
            die("%s: no EMIT_ tables found" % args.compare)
        bad, ignored = compare(tables, theirs, args.compare)
        if bad:
            die("%d table(s) differ" % bad)
        print("gen_ps7_init_gpl: ok: %s holds the same %d operations in the "
              "same %d tables%s" % (args.compare, count, ntables,
              ("; not compared, run by nothing: %s" % ", ".join(ignored))
              if ignored else ""))
        return 0

    if args.check:
        try:
            with open(OUT) as f:
                have = f.read()
        except IOError:
            die("%s is missing: run the generator and commit it" % OUT)
        if have != text:
            die("%s is not what vivado/ps7_init.ops gives today; run the "
                "generator and commit, or find out why the routine moved"
                % os.path.relpath(OUT, REPO))
        # Reading our own output back must give the .ops again, or the
        # extractor used by --compare is not reading what the generator wrote.
        back = read_c(OUT)
        bad, _ = compare(tables, back, "the generated file read back")
        if bad:
            die("the generated file does not read back as the .ops")
        print("gen_ps7_init_gpl: ok: %s is current (%d operations, %d "
              "tables)" % (os.path.relpath(OUT, REPO), count, ntables))
        return 0

    with open(OUT, "w") as f:
        f.write(text)
    print("gen_ps7_init_gpl: wrote %s (%d operations, %d tables)"
          % (os.path.relpath(OUT, REPO), count, ntables))
    return 0


if __name__ == "__main__":
    sys.exit(main())
