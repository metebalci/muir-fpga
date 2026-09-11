#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Compares a capture taken off the board against muir's own reference trace,
# column by column.
#
# Everything in this repository agrees with muir in simulation.  Nothing has
# ever compared what the *board* computes against what the model computes,
# because the board's observable surface is six LEDs.  An in-fabric probe
# --- `rtl/plumbing/xilinx7/cadr_probe.sv` --- records the datapath one sample per microcycle
# from microcycle zero and reads it out over JTAG; this turns that readout
# into a verdict.
#
#     tools/probe_check.py --capture capture.csv --golden build/rtl.golden
#
# WHAT IT COMPARES.  Only the columns the capture itself carries.  The subset
# is the probe's to choose, so the column list is taken from the
# capture's own header and every name in it must exist in the trace --- a name
# that does not is an error and not a column quietly skipped.
#
# WHY COLUMN BY COLUMN.  One bad column and one bad row look identical in a
# total.  The per-column breakdown is what says which of those it is, and
# CLAUDE.md is explicit that a column-by-column diff is what makes a claim
# about a trace believable.
#
# ALIGNMENT IS A CLAIM, NOT AN ASSUMPTION.  The capture is meant to begin at
# microcycle zero.  Three independent things are checked, and each is named on
# the output so a reader can see which of them actually held:
#
#   1. the capture's own `cycle` column, if it carries one, must count
#      0, 1, 2, ... with no gap and no repeat --- the direct proof, and the
#      reason the probe spends 32 bits of every sample on a microcycle
#      counter;
#   2. the export's TRIGGER column, if present, must be set on sample 0 and
#      on no other sample, and a declared trigger position must be zero;
#   3. the content itself, compared at offset zero and nowhere else.
#
# On disagreement the tool *diagnoses* whether some other offset would have
# matched, and says so, but never adopts it.  A tool that slides the window
# until it matches will always find something.
#
# ------------------------------------------------------------------ format --
#
# THE CAPTURE FILE.  What Vivado's hardware manager writes with
#
#     write_hw_ila_data -csv_file capture.csv [current_hw_ila_data]
#
# is accepted as it comes.  Concretely, the reader takes:
#
#   * any number of metadata lines before the header.  `Radix - HEX`,
#     `Buffer Sample Count: N`, `Window Sample Count: N`, `Trigger Position: N`,
#     `Device:` and `Design:` are read; anything else is ignored.
#   * a header line, found as the first line that names at least one column of
#     the reference trace.  Comma-separated, or whitespace-separated with a
#     leading `#` (the trace's own form).
#   * column names decorated the way Vivado decorates them:
#     `slot_0 : u_ila_0 : pc[13:0]` is the column `pc`.  A `[hi:lo]` or `[n]`
#     width suffix is stripped, everything up to the last `:` is dropped, and
#     MIT's own names are mangled the way `rtl/machine/cadr_cables.map` mangles them:
#     a leading `-` becomes `n_`, and `.`, space, `/` and `>` become `_`.  So
#     a column named `-VMAOK` is the trace's `n_vmaok`.
#   * the housekeeping columns `Sample in Buffer`, `Sample in Window` and
#     `TRIGGER`, which are used and not compared.
#   * one row per sample, in sample order, oldest first.
#
# RADIX.  `Radix - HEX` is what the export should declare and what the trace
# itself uses.  A declared radix is obeyed; with none declared the values are
# read as hexadecimal and the output says that it assumed so, because a
# capture exported UNSIGNED and read as hex disagrees quietly rather than
# loudly.  `--radix` overrides both.
#
# A SHORT CAPTURE IS NOT A FAILURE.  The probe holds thousands of samples and
# the trace holds 600,000 microcycles, so a capture will always be a prefix.
# What is compared is the length of the capture, and the fraction of the run
# that reaches is printed rather than left to be assumed.  A capture that is
# *ragged* --- a row with the wrong number of fields, or fewer rows than its
# own header declares --- is a failure, because that is a readout that went
# wrong rather than a buffer that is short.
#
# THE THREE NANOSECOND COLUMNS.  `ns`, `stall` and `halted` are times, and
# CLAUDE.md records that muir's clock is continuous where the fabric's is a
# 5 ns grid: 30,088 microcycles of the boot PROM come out 1 to 4 ns long, each
# hang re-anchoring so the slip cannot accumulate.  Those three are therefore
# compared to within 4 ns and the slip is counted and printed; every other
# column is compared exactly.
#
# EXIT STATUS.  0 the hardware agreed, 1 it disagreed (or could not be shown
# to be aligned), 2 the capture could not be read at all.

import argparse
import io
import os
import re
import sys
import tempfile

# The three columns that carry a time rather than a value, and the bound
# CLAUDE.md records for the fabric's 5 ns grid against muir's continuous one.
TIMING_COLUMNS = ("ns", "stall", "halted")
TIMING_TOLERANCE_NS = 4

# Columns an export carries about itself.  Used, never compared.
HOUSEKEEPING = ("sample_in_buffer", "sample_in_window", "sample", "trigger",
                "radix", "time", "time_ns")

RADIX_NAMES = {
    "hex": 16, "hexadecimal": 16, "h": 16,
    "unsigned": 10, "signed": 10, "decimal": 10, "dec": 10, "d": 10,
    "binary": 2, "bin": 2, "b": 2,
    "octal": 8, "oct": 8, "o": 8,
}
RADIX_WORD = {16: "hexadecimal", 10: "decimal", 2: "binary", 8: "octal"}


class Bad(Exception):
    """The capture or the trace could not be read.  Exit status 2."""


# --------------------------------------------------------------- names -----

_WIDTH = re.compile(r"\[\s*\d+\s*(:\s*\d+\s*)?\]$")


def normalise(name):
    """A column name as the reference trace spells it, or '' for a blank field.

    Strips Vivado's decoration and applies the repository's own mangling, so
    `slot_0 : u_ila_0 : -VMAOK[0:0]` and `n_vmaok` are the same column.
    """
    s = name.strip().strip('"').strip("'").strip()
    s = _WIDTH.sub("", s).strip()
    if ":" in s:
        s = s.split(":")[-1].strip()
    if not s:
        return ""
    if s.startswith("-"):
        s = "n_" + s[1:]
    for ch in ". /><\t":
        s = s.replace(ch, "_")
    s = s.lower()
    if s and s[0].isdigit():
        s = "x" + s
    return s


def parse_value(text, radix, where):
    t = text.strip().strip('"').replace("_", "").replace(" ", "")
    if not t:
        raise Bad("%s: empty value" % where)
    low = t.lower()
    for pre in ("0x", "'h", "16#"):
        if low.startswith(pre):
            t, low = t[len(pre):], low[len(pre):]
            radix = 16
            break
    if low.startswith("0b"):
        t, radix = t[2:], 2
    try:
        return int(t, radix)
    except ValueError:
        # X and U are the interesting ones: a probe that reads out undriven
        # bits says so here rather than comparing as zero.
        raise Bad("%s: %r is not a %s number; if the capture was exported "
                  "with another radix, say so with --radix"
                  % (where, text.strip(), RADIX_WORD.get(radix, radix)))


# -------------------------------------------------------------- reading ----

def read_golden(path, nrows):
    """The trace's column names, and up to `nrows` rows of it as ints."""
    names, rows = None, []
    try:
        f = open(path, "r")
    except OSError as e:
        raise Bad("cannot read the reference trace %s: %s" % (path, e))
    with f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#"):
                if names is None:
                    names = line[1:].split()
                continue
            if not line.strip():
                continue
            if names is None:
                raise Bad("%s has data before its header line" % path)
            fields = line.split()
            if len(fields) != len(names):
                raise Bad("%s: a row has %d fields where the header names %d"
                          % (path, len(fields), len(names)))
            rows.append(tuple(int(x, 16) for x in fields))
            if len(rows) >= nrows:
                break
    if not names:
        raise Bad("%s names no columns" % path)
    return names, rows


def count_golden_rows(path):
    n = 0
    with open(path, "r") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            n += 1
    return n


class Capture:
    def __init__(self):
        self.meta = {}
        self.raw_names = []
        self.names = []          # normalised, per raw column, '' where dropped
        self.rows = []           # list of tuples of ints, one per sample
        self.radix = 16
        self.radix_declared = False
        self.trigger_col = None
        self.header_line = 0
        self.path = ""


def _split(line):
    """Fields of a header or data line, and whether it was comma separated."""
    if line.lstrip().startswith("#"):
        return line.lstrip()[1:].split(), False
    if "," in line:
        return line.split(","), True
    return line.split(), False


def read_capture(path, golden_names, radix_override=None, renames=None):
    cap = Capture()
    cap.path = path
    renames = renames or {}
    golden_set = set(golden_names)
    try:
        with open(path, "r") as f:
            lines = f.read().splitlines()
    except OSError as e:
        raise Bad("cannot read the capture %s: %s" % (path, e))

    meta_re = re.compile(r"^\s*([A-Za-z][A-Za-z ]*?)\s*[-:]\s*(.+?)\s*$")
    header_at = None
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        fields, _ = _split(line)
        cooked = [renames.get(normalise(x), normalise(x)) for x in fields]
        if any(c in golden_set for c in cooked):
            header_at = i
            break
        m = meta_re.match(line)
        if m:
            cap.meta[m.group(1).strip().lower()] = m.group(2).strip()
    if header_at is None:
        raise Bad("%s: no header line names any column of the reference "
                  "trace; is this a capture, as `boards/arty-z7-20/vivado/probe.tcl` or a "
                  "Vivado ILA export writes one?" % path)

    cap.header_line = header_at + 1
    raw, comma = _split(lines[header_at])
    cap.raw_names = [x.strip() for x in raw]
    cap.names = [renames.get(normalise(x), normalise(x)) for x in raw]

    r = cap.meta.get("radix")
    if r and r.strip().lower() in RADIX_NAMES:
        cap.radix = RADIX_NAMES[r.strip().lower()]
        cap.radix_declared = True
    if radix_override:
        cap.radix = RADIX_NAMES[radix_override]
        cap.radix_declared = True

    for j, n in enumerate(cap.names):
        if n == "trigger":
            cap.trigger_col = j

    ncols = len(raw)
    for i in range(header_at + 1, len(lines)):
        line = lines[i]
        if not line.strip():
            continue
        fields = line.split(",") if comma else line.split()
        if len(fields) != ncols:
            raise Bad("%s line %d: %d fields where the header names %d; the "
                      "readout is ragged, not merely short"
                      % (path, i + 1, len(fields), ncols))
        row = []
        for j, v in enumerate(fields):
            if not cap.names[j]:
                row.append(0)
                continue
            row.append(parse_value(v, cap.radix, "%s line %d, column %s"
                                   % (path, i + 1, cap.raw_names[j] or j)))
        cap.rows.append(tuple(row))
    return cap


# ------------------------------------------------------------ comparing ----

def hx(v):
    return format(v, "x")


def compare(cap, golden_names, golden_rows, total_rows, max_examples,
            out, err):
    """Returns an exit status.  Everything it concludes, it prints."""
    gidx = {n: i for i, n in enumerate(golden_names)}
    problems = 0

    # Which columns are compared, and which the trace does not have.
    compared = []   # (capture column index, golden column index, name)
    unknown = []
    for j, n in enumerate(cap.names):
        if not n or n in HOUSEKEEPING:
            continue
        if n not in gidx:
            unknown.append(cap.raw_names[j])
            continue
        compared.append((j, gidx[n], n))
    if unknown:
        err.write("FAIL: the capture names %d column%s the reference trace "
                  "does not have: %s\n"
                  % (len(unknown), "" if len(unknown) == 1 else "s",
                     " ".join(unknown)))
        err.write("      the trace's columns are: %s\n"
                  % " ".join(golden_names))
        return 1
    if not compared:
        err.write("FAIL: the capture carries no column of the reference "
                  "trace, so there is nothing to compare\n")
        return 1

    n_cap = len(cap.rows)
    if n_cap == 0:
        err.write("FAIL: the capture holds no samples\n")
        return 1

    declared, said = None, None
    for key in ("buffer sample count", "window sample count", "sample count"):
        if key in cap.meta:
            try:
                declared, said = int(cap.meta[key]), key
            except ValueError:
                declared = None
            break
    if declared is not None and declared != n_cap:
        err.write("FAIL: the capture declares %s of %d and carries %d row%s; "
                  "the readout is truncated\n"
                  % (said, declared, n_cap, "" if n_cap == 1 else "s"))
        return 1

    if len(golden_rows) < n_cap:
        err.write("FAIL: the capture is %d samples long and the reference "
                  "trace has only %d microcycles; the capture cannot be a "
                  "prefix of this run\n" % (n_cap, len(golden_rows)))
        return 1

    # ---- alignment, claimed at microcycle zero and checked three ways.
    proofs, align_fail = [], []

    if cap.trigger_col is not None:
        marks = [i for i, r in enumerate(cap.rows) if r[cap.trigger_col]]
        if marks == [0]:
            proofs.append("TRIGGER is set on sample 0 and on no other")
        elif not marks:
            align_fail.append("the export's TRIGGER column is set on no "
                              "sample, so the capture does not say where it "
                              "was armed")
        else:
            align_fail.append("the export's TRIGGER column is set on sample%s "
                              "%s, not on sample 0"
                              % ("" if len(marks) == 1 else "s",
                                 ", ".join(str(m) for m in marks[:8])))
    tp = cap.meta.get("trigger position")
    if tp is not None:
        try:
            if int(tp) != 0:
                align_fail.append("the export declares a trigger position of "
                                  "%s, so its first sample is not the trigger"
                                  % tp)
            else:
                proofs.append("the export declares a trigger position of 0")
        except ValueError:
            pass

    cyc_cap = next((j for j, gi, n in compared if n == "cycle"), None)
    if cyc_cap is not None:
        want = [i for i in range(n_cap)]
        got = [cap.rows[i][cyc_cap] for i in range(n_cap)]
        if got == want:
            proofs.append("the capture's own cycle column counts 0 to %s "
                          "with no gap and no repeat" % hx(n_cap - 1))
        else:
            first = next(i for i in range(n_cap) if got[i] != want[i])
            align_fail.append("the capture's own cycle column reads %s at "
                              "sample %d where a run from microcycle zero "
                              "would read %s" % (hx(got[first]), first,
                                                 hx(want[first])))
    else:
        proofs.append("no cycle column in the capture, so alignment rests on "
                      "the content and on the trigger alone")

    # ---- the diff itself, at offset zero and nowhere else.
    per_col = {}
    for j, gi, name in compared:
        tol = TIMING_TOLERANCE_NS if name in TIMING_COLUMNS else 0
        bad, examples, worst = 0, [], 0
        seen = set()
        for i in range(n_cap):
            got, want = cap.rows[i][j], golden_rows[i][gi]
            seen.add(got)
            d = got - want
            if abs(d) > tol:
                bad += 1
                if len(examples) < max_examples:
                    examples.append((i, got, want))
            elif d:
                worst = max(worst, abs(d))
        per_col[name] = dict(bad=bad, examples=examples, distinct=len(seen),
                             slip=worst, tol=tol)

    total_bad = sum(c["bad"] for c in per_col.values())
    wrong_cols = [n for _, _, n in compared if per_col[n]["bad"]]

    if align_fail or total_bad:
        if align_fail:
            err.write("FAIL: the capture cannot be shown to begin at "
                      "microcycle 0\n")
            for line in align_fail:
                err.write("    %s\n" % line)
        if total_bad:
            err.write("FAIL: %d of %d compared column%s disagree with muir "
                      "over %s microcycle%s, %s disagreeing cell%s in all\n"
                      % (len(wrong_cols), len(compared),
                         "" if len(compared) == 1 else "s",
                         format(n_cap, ","), "" if n_cap == 1 else "s",
                         format(total_bad, ","),
                         "" if total_bad == 1 else "s"))
            for _, _, name in compared:
                c = per_col[name]
                if not c["bad"]:
                    continue
                err.write("    %-10s %s of %s row%s (%.2f%%)\n"
                          % (name, format(c["bad"], ","), format(n_cap, ","),
                             "" if n_cap == 1 else "s",
                             100.0 * c["bad"] / n_cap))
                for i, got, want in c["examples"]:
                    err.write("        microcycle %s: capture %s, muir %s\n"
                              % (hx(i), hx(got), hx(want)))
                if c["bad"] > len(c["examples"]):
                    err.write("        and %s more\n"
                              % format(c["bad"] - len(c["examples"]), ","))
            agreeing = [n for _, _, n in compared if not per_col[n]["bad"]]
            if agreeing:
                err.write("    agreeing on every row: %s\n" % " ".join(agreeing))
        diagnose(cap, compared, golden_rows, n_cap, err)
        return 1

    # ---- agreement.  Say what was checked and how much of it.
    names = [n for _, _, n in compared]
    out.write("ok: %s captured microcycle%s agree with muir's rtl engine\n"
              % (format(n_cap, ","), "" if n_cap == 1 else "s"))
    out.write("    %d of the trace's %d columns compared: %s\n"
              % (len(compared), len(golden_names), " ".join(names)))
    out.write("    microcycles 0 to %s, %s of the trace's %s (%.2f%% of "
              "the run)\n"
              % (hx(n_cap - 1), format(n_cap, ","), format(total_rows, ","),
                 100.0 * n_cap / total_rows))
    out.write("    radix %s, %s\n"
              % (RADIX_WORD.get(cap.radix, cap.radix),
                 "declared by the capture" if cap.radix_declared else
                 "not declared by the capture and assumed, the trace's own"))
    out.write("    aligned at microcycle 0, and this is how:\n")
    for p in proofs:
        out.write("        %s\n" % p)
    slipped = [n for n in names if per_col[n]["slip"]]
    if slipped:
        out.write("    within %d ns rather than exact, the 5 ns grid against "
                  "muir's continuous clock: %s\n"
                  % (TIMING_TOLERANCE_NS,
                     " ".join("%s to %d ns" % (n, per_col[n]["slip"])
                              for n in slipped)))
    out.write("    distinct values: %s\n"
              % "  ".join("%s %s" % (n, format(per_col[n]["distinct"], ","))
                          for n in names))
    flat = [n for n in names if per_col[n]["distinct"] == 1 and n != "cycle"]
    if flat:
        out.write("    constant over the whole capture, and so checked "
                  "vacuously: %s\n" % " ".join(flat))
    missing = [n for n in golden_names if n not in set(names)]
    if missing:
        out.write("    not carried by this capture, and so not checked:\n")
        for k in range(0, len(missing), 8):
            out.write("        %s\n" % " ".join(missing[k:k + 8]))
    return 0


def diagnose(cap, compared, golden_rows, n_cap, err, window=8):
    """Would some other offset have matched?  Said, never adopted."""
    def cells(d):
        bad = pairs = 0
        for i in range(n_cap):
            g = i + d
            if g < 0 or g >= len(golden_rows):
                continue
            pairs += 1
            for j, gi, name in compared:
                tol = TIMING_TOLERANCE_NS if name in TIMING_COLUMNS else 0
                if abs(cap.rows[i][j] - golden_rows[g][gi]) > tol:
                    bad += 1
        return bad, pairs

    here, pairs_here = cells(0)
    best = None
    for d in range(-window, window + 1):
        if d == 0:
            continue
        bad, pairs = cells(d)
        if pairs < n_cap // 2:
            continue
        if best is None or bad < best[1]:
            best = (d, bad, pairs)
    if best is None or best[1] >= here:
        err.write("    no offset within %d microcycles either way matches "
                  "better than the offset of zero the capture claims, so this "
                  "is not a misalignment\n" % window)
        return
    d, bad, pairs = best
    err.write("    a diagnosis and not an alignment this tool will adopt: "
              "against the trace shifted by %+d, %s of %s compared cells "
              "disagree, where at the claimed offset of zero %s of %s do\n"
              % (d, format(bad, ","), format(pairs * len(compared), ","),
                 format(here, ","), format(pairs_here * len(compared), ",")))
    if bad == 0:
        err.write("    the capture appears to begin at microcycle %d rather "
                  "than 0; fix the probe's arming, do not shift the "
                  "comparison\n" % d)


# ------------------------------------------------------------- self test ---

VIVADO_HEAD = """Waveform Export Data
Date: Wed Sep 09 12:00:00 2026
Device: xc7z020clg400-1
Design: cadr_machine
Radix - %s
Buffer Sample Count: %d
Window Sample Count: %d
Trigger Position: 0

"""


def synth(path, golden_names, golden_rows, cols, n, start=0, radix="HEX",
          trigger=True, declared=None, damage=None, extra=None):
    """A capture as Vivado would export one, made out of the trace itself."""
    base = {16: "%x", 10: "%d", 2: None}[RADIX_NAMES[radix.lower()]]
    gidx = {x: i for i, x in enumerate(golden_names)}

    def fmt(v):
        return base % v if base else format(v, "b")

    # Decorated the way the hardware manager decorates them, and one of them
    # spelled MIT's way, so the mangling is exercised rather than assumed.
    def decorated(name, k):
        shown = "-VMAOK" if name == "n_vmaok" else name
        return "slot_0 : u_ila_0 : %s[%d:0]" % (shown, k)

    head = [] if radix is None else []
    body = []
    for i in range(n):
        g = golden_rows[start + i]
        vals = [str(i), str(i), "1" if (trigger and i == 0) else "0"]
        vals += [fmt(g[gidx[c]]) for c in cols]
        if extra:
            vals += [fmt(0) for _ in extra]
        body.append(",".join(vals))
    if damage:
        body = damage(body)
    names = ["Sample in Buffer", "Sample in Window", "TRIGGER"]
    names += [decorated(c, 31) for c in cols]
    if extra:
        names += [decorated(c, 7) for c in extra]
    with open(path, "w") as f:
        f.write(VIVADO_HEAD % (radix, declared if declared is not None else n,
                               declared if declared is not None else n))
        f.write(",".join(names) + "\n")
        f.write("\n".join(body) + "\n")


def self_test(golden_path, out):
    """Every failure mode, run against a capture made from the trace itself.

    A check nobody has seen fail is not a check, and no board exists to fail
    against, so the tool is made to fail here instead.
    """
    n = 512
    names, rows = read_golden(golden_path, n + 32)
    if len(rows) < n + 32:
        raise Bad("the reference trace is too short for the self test")
    cols = ["cycle", "pc", "ir", "a", "m", "alu", "ob", "lc", "jcond",
            "n_vmaok", "vma", "md"]

    cases = []

    def case(name, expect, build, wants=()):
        cases.append((name, expect, build, wants))

    def wrap(fn):
        def build(d):
            p = os.path.join(d, "capture.csv")
            fn(p)
            return p
        return build

    case("a capture that agrees", 0,
         wrap(lambda p: synth(p, names, rows, cols, n)),
         ("ok:", "512 captured microcycles", "aligned at microcycle 0"))

    case("a short but complete capture", 0,
         wrap(lambda p: synth(p, names, rows, cols, 64)),
         ("ok:", "64 captured microcycles"))

    case("a capture exported with an unsigned radix", 0,
         wrap(lambda p: synth(p, names, rows, cols, n, radix="UNSIGNED")),
         ("ok:", "radix decimal, declared"))

    def one_cell(p):
        synth(p, names, rows, cols, n)
        lines = open(p).read().splitlines()
        h = lines.index([l for l in lines if l.startswith("Sample in")][0])
        f = lines[h + 1 + 100].split(",")
        f[3 + cols.index("pc")] = "dead"
        lines[h + 1 + 100] = ",".join(f)
        open(p, "w").write("\n".join(lines) + "\n")

    case("one wrong value, one column, one row", 1, wrap(one_cell),
         ("FAIL:", "1 of 12 compared columns", "pc", "1 of 512 rows",
          "microcycle 64:", "capture dead"))

    def whole_col(p):
        synth(p, names, rows, cols, n)
        lines = open(p).read().splitlines()
        h = lines.index([l for l in lines if l.startswith("Sample in")][0])
        k = 3 + cols.index("a")
        for i in range(h + 1, len(lines)):
            f = lines[i].split(",")
            f[k] = format(int(f[k], 16) ^ 1, "x")
            lines[i] = ",".join(f)
        open(p, "w").write("\n".join(lines) + "\n")

    case("a whole column wrong", 1, wrap(whole_col),
         ("FAIL:", "512 of 512 rows (100.00%)", "agreeing on every row"))

    case("a capture offset by one microcycle", 1,
         wrap(lambda p: synth(p, names, rows, cols, n, start=1)),
         ("FAIL: the capture cannot be shown to begin at microcycle 0",
          "cycle column reads 1 at sample 0"))

    off = [c for c in cols if c != "cycle"]
    case("the same, with no cycle column to say so", 1,
         wrap(lambda p: synth(p, names, rows, off, n, start=1)),
         ("FAIL:", "a diagnosis and not an alignment",
          "appears to begin at microcycle 1"))

    case("a capture truncated after its header was written", 1,
         wrap(lambda p: synth(p, names, rows, cols, 300, declared=1024)),
         ("FAIL:", "declares buffer sample count of 1024 and carries 300"))

    case("a capture whose last row was cut short", 2,
         wrap(lambda p: synth(p, names, rows, cols, n,
                              damage=lambda b: b[:-1] + [",".join(
                                  b[-1].split(",")[:4])])),
         ("fields where the header names",))

    case("a column the trace does not have", 1,
         wrap(lambda p: synth(p, names, rows, cols, n, extra=["mystery"])),
         ("FAIL: the capture names 1 column the reference trace does not "
          "have", "mystery"))

    # The three nanosecond columns, and the bound they are compared to.
    def shift_ns(delta, columns):
        def build(path):
            synth(path, names, rows, columns, n)
            lines = open(path).read().splitlines()
            h = [i for i, l in enumerate(lines)
                 if l.startswith("Sample in")][0]
            k = 3 + columns.index("ns")
            for i in range(h + 1, len(lines)):
                f = lines[i].split(",")
                f[k] = format(int(f[k], 16) + delta, "x")
                lines[i] = ",".join(f)
            open(path, "w").write("\n".join(lines) + "\n")
        return build

    ns_cols = cols + ["ns"]
    case("a time column 3 ns off, inside the 5 ns grid's slip", 0,
         wrap(shift_ns(3, ns_cols)),
         ("ok:", "within 4 ns rather than exact", "ns to 3 ns"))

    case("a time column 6 ns off, outside it", 1,
         wrap(shift_ns(6, ns_cols)),
         ("FAIL:", "ns         512 of 512 rows (100.00%)"))

    case("a capture with no samples at all", 1,
         wrap(lambda p: synth(p, names, rows, cols, 0, declared=0)),
         ("FAIL: the capture holds no samples",))

    case("a file that is not a capture", 2,
         wrap(lambda p: open(p, "w").write("nothing to see here\n")),
         ("no header line names any column",))

    case("a trigger that does not mark sample 0", 1,
         wrap(lambda p: synth(p, names, rows, off, n, trigger=False)),
         ("FAIL: the capture cannot be shown to begin at microcycle 0",
          "TRIGGER column is set on no sample"))

    width = max(len(c[0]) for c in cases)
    failures = 0
    out.write("self test: %d cases, each a capture made out of %s\n"
              % (len(cases), golden_path))
    with tempfile.TemporaryDirectory() as d:
        for name, expect, build, wants in cases:
            path = build(d)
            o, e = io.StringIO(), io.StringIO()
            got = run(["--capture", path, "--golden", golden_path], o, e)
            text = o.getvalue() + e.getvalue()
            missing = [w for w in wants if w not in text]
            ok = (got == expect) and not missing
            out.write("    %-*s  expected %d, got %d  %s\n"
                      % (width, name, expect, got, "ok" if ok else "WRONG"))
            if not ok:
                failures += 1
                if got != expect:
                    out.write("        exit status %d, wanted %d\n"
                              % (got, expect))
                for w in missing:
                    out.write("        said nothing about: %r\n" % w)
                for line in text.splitlines():
                    out.write("        | %s\n" % line)
    if failures:
        out.write("self test: %d of %d cases WRONG\n" % (failures, len(cases)))
        return 1
    out.write("self test: %d cases, all as expected.  Agreement on a capture "
              "built out of the trace itself, at two lengths and two radixes,\n"
              "           and on a time column 3 ns adrift of it.  A named "
              "failure on a wrong cell, a wrong column, an offset of one with\n"
              "           and without a cycle column to say so, a truncated "
              "readout, a ragged row, an unknown column, an empty capture, a\n"
              "           file that is not a capture, a trigger that does not "
              "mark sample 0, and a time column 6 ns adrift\n" % len(cases))
    return 0


# ------------------------------------------------------------------ main ---

def run(argv, out=None, err=None):
    out = out or sys.stdout
    err = err or sys.stderr
    p = argparse.ArgumentParser(
        prog="tools/probe_check.py", add_help=True,
        description="Compare a capture taken off the board against muir's "
                    "reference trace, column by column.")
    p.add_argument("--capture", help="the capture to check")
    p.add_argument("--golden", default="build/rtl.golden",
                   help="the reference trace (default build/rtl.golden)")
    p.add_argument("--radix", choices=sorted(set(RADIX_NAMES)),
                   help="read the capture's values in this radix, overriding "
                        "any the export declares")
    p.add_argument("--rename", action="append", default=[],
                   metavar="NAME=COLUMN",
                   help="a capture column that is a trace column under "
                        "another name; repeatable")
    p.add_argument("--examples", type=int, default=5, metavar="N",
                   help="disagreeing rows to print per column (default 5)")
    p.add_argument("--self-test", action="store_true",
                   help="run this tool against captures made out of the "
                        "trace, including ones it must reject")
    a = p.parse_args(argv)

    try:
        if a.self_test:
            return self_test(a.golden, out)
        if not a.capture:
            p.print_usage(err)
            err.write("tools/probe_check.py: --capture is required "
                      "(or --self-test)\n")
            return 2
        renames = {}
        for r in a.rename:
            if "=" not in r:
                err.write("--rename wants NAME=COLUMN, not %r\n" % r)
                return 2
            k, v = r.split("=", 1)
            renames[normalise(k)] = normalise(v)

        names, _ = read_golden(a.golden, 1)
        cap = read_capture(a.capture, names, a.radix, renames)
        # Only the window the capture reaches is held, plus the few rows the
        # offset diagnosis needs; the whole trace's length is counted
        # separately so the coverage printed is of the run and not of the
        # window --- 120 ms on 600,000 rows.
        want = max(len(cap.rows) + 8, 1)
        names, rows = read_golden(a.golden, want)
        total = len(rows) if len(rows) < want else count_golden_rows(a.golden)
        return compare(cap, names, rows, total, a.examples, out, err)
    except Bad as e:
        err.write("FAIL: %s\n" % e)
        return 2


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
