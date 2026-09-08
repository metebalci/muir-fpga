# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The checks, checked.
#
# `make check` passing says the fabric agrees with muir.  It says nothing about
# whether it would still pass if the fabric were wrong, and that is the claim
# the whole project rests on.  So: take each check, break the design it is
# holding, and see whether it notices.  A mutation the check catches is a
# check earning its keep; one it does not is a hole.
#
# Every mutation in list.txt is a bug in the fabric, and most of them are bugs
# that were really made --- CLAUDE.md's "What went wrong, and what caught it"
# is the seed of the list, because each of those passed something before it
# was found.
#
# THE WORKING TREE IS NEVER MUTATED.  Each mutation gets a copy of rtl/ and
# tb/ under --work and is applied, built and run there.  The tree is shared
# with other sessions; a runner that edited it in place and then crashed would
# leave corrupted source behind.
#
# THREE THINGS ARE FAILURES OF THE RUN, NOT CAUGHT MUTATIONS, and each exits
# non-zero with the mutation named:
#
#   the mutation did not apply --- its `@old` text is not in the file, or is
#   there more than once.  Silently mutating nothing would give a clean build,
#   a passing check, and a report of SURVIVED: a finding that is not real.
#
#   the build failed.  This is CLAUDE.md's own lesson, from the other side:
#   two mutations were once reported as surviving when lint had rejected them
#   and a stale binary ran.  Nothing here reuses a build directory, and a
#   build that fails is reported as BROKEN rather than as anything else.
#
#   the baseline failed.  Before any mutation runs, the unmutated copy has to
#   pass every check that has mutations against it.  "The check caught it" is
#   worth nothing from a check that was already failing.
#
# A mutation that survives is a finding.  It is not tuned away and not dropped
# from the list: it says a check is weaker than it looks, and the fix belongs
# in the check.

import argparse
import concurrent.futures
import filecmp
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
LIST = os.path.join(HERE, "list.txt")

# The six checks stage 3 froze, exactly as the Makefile builds them.  Kept
# beside it by hand: two descriptions of one thing, and check_makefile()
# below is what warns when they stop agreeing.
#
#   sources   what verilate, in the Makefile's order
#   tb        the C++ testbench, or None for a lint-only check
#   flags     verilator flags beyond VFLAGS
#   golden    the reference trace the testbench is given, or None
#
# `microcycle` is deliberately absent.  Stage 4 is being written right now and
# is not frozen; it gets mutations when a slice lands.
CHECKS = {
    "phase_gen": {
        "sources": ["rtl/cadr_phase_gen.sv"],
        "top": "cadr_phase_gen",
        "tb": "tb/cadr_phase_gen_tb.cpp",
        "flags": [],
        "golden": "phase_gen.golden",
    },
    "cables": {
        # Lint alone is not what this check holds to; see cables_check().
        "sources": ["rtl/cadr_cables.svh", "rtl/cadr_cables_lint.sv"],
        "top": "cadr_cables_lint",
        "tb": None,
        "flags": ["-Irtl"],
        "golden": None,
    },
    "busint_xbus": {
        "sources": ["rtl/cadr_busint_xbus.sv"],
        "top": "cadr_busint_xbus",
        "tb": "tb/cadr_busint_xbus_tb.cpp",
        "flags": [],
        "golden": "busint_xbus.golden",
    },
    "xbus_decode": {
        "sources": ["rtl/cadr_xbus_decode.sv"],
        "top": "cadr_xbus_decode",
        "tb": "tb/cadr_xbus_decode_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2"],
        "golden": "xbus_decode.golden",
    },
    "memory_path": {
        "sources": [
            "rtl/cadr_ddr_map.sv",
            "rtl/cadr_xbus_decode.sv",
            "rtl/cadr_busint_xbus.sv",
            "rtl/cadr_xbus_ddr.sv",
            "rtl/cadr_memory_path.sv",
        ],
        "top": "cadr_memory_path",
        "tb": "tb/cadr_memory_path_tb.cpp",
        "flags": ["-Irtl"],
        # The memory path is driven from the bus interface's own trace: the
        # same stimulus, through the whole path.
        "golden": "busint_xbus.golden",
    },
    "axi_master": {
        # No muir reference, so no trace: the testbench is the stimulus.
        "sources": ["rtl/cadr_axi_master.sv"],
        "top": "cadr_axi_master",
        "tb": "tb/cadr_axi_master_tb.cpp",
        "flags": [],
        "golden": None,
    },
}

# The three files golden/src/cables.rs writes.  `current` regenerates them and
# fails if anything moved; this does the same to a copy.
GENERATED = [
    "rtl/cadr_cables.svh",
    "rtl/cadr_cables.map",
    "rtl/cadr_cables_lint.sv",
]

# What a mutation run can come to.  CAUGHT is the only good one.
CAUGHT = "caught"        # the check failed, as it should have
SURVIVED = "survived"    # the check passed with the bug in: a hole
BROKEN = "broken"        # the build failed; not a verdict on the check
UNAPPLIED = "unapplied"  # the @old text was not there exactly once


class Mutation(object):
    def __init__(self, name, check, path, notes, old, new, line):
        self.name = name
        self.check = check
        self.path = path
        self.notes = notes
        self.old = old
        self.new = new
        self.line = line          # where it is in list.txt, for error messages
        self.verdict = None
        self.detail = ""
        self.also = []            # for a survivor: other checks that missed it


def parse(path):
    """Read list.txt.

    Each record names a check, a file, and an exact block of source with what
    to put in its place.  Blocks are literal and whole lines: no line numbers
    and no context, so a record rots only when the lines it actually names
    change, and it reads as prose about the bug rather than as a diff.
    """
    with open(path) as f:
        lines = f.read().split("\n")

    mutations = []
    i = 0
    cur = None
    field = None   # None, "old" or "new" --- which block we are inside
    old, new, notes = [], [], []

    while i < len(lines):
        line = lines[i]
        i += 1
        n = i  # 1-based line number of `line`

        if field in ("old", "new"):
            # Inside a block every line is literal source, so only the three
            # delimiters are read and nothing else is stripped or trimmed.
            if line == "@new":
                if field != "old":
                    die("%s:%d: @new outside @old" % (path, n))
                field = "new"
                continue
            if line == "@end":
                if cur is None:
                    die("%s:%d: @end without @mutation" % (path, n))
                cur["old"] = "".join(s + "\n" for s in old)
                cur["new"] = "".join(s + "\n" for s in new)
                mutations.append(
                    Mutation(cur["name"], cur["check"], cur["file"], notes,
                             cur["old"], cur["new"], cur["line"]))
                cur, field = None, None
                old, new, notes = [], [], []
                continue
            (old if field == "old" else new).append(line)
            continue

        if not line.strip() or line.startswith("#"):
            continue

        if line.startswith("@mutation "):
            if cur is not None:
                die("%s:%d: @mutation inside a record" % (path, n))
            cur = {"name": line[len("@mutation "):].strip(), "line": n,
                   "check": None, "file": None}
            old, new, notes = [], [], []
        elif cur is None:
            die("%s:%d: %s outside a record" % (path, n, line.split()[0]))
        elif line.startswith("@check "):
            cur["check"] = line[len("@check "):].strip()
        elif line.startswith("@file "):
            cur["file"] = line[len("@file "):].strip()
        elif line == "@note" or line.startswith("@note "):
            # A bare `@note` is a blank line between paragraphs.
            notes.append(line[len("@note"):].strip())
        elif line == "@old":
            for key in ("check", "file"):
                if not cur[key]:
                    die("%s:%d: `%s` has no @%s" % (path, n, cur["name"], key))
            field = "old"
        else:
            die("%s:%d: cannot read: %s" % (path, n, line))

    if cur is not None or field is not None:
        die("%s: the last record has no @end" % path)
    if not mutations:
        die("%s: no mutations" % path)

    # Names are how a survivor is reported and how CLAUDE.md's claim is read
    # against the list, so two of them may not collide.
    seen = {}
    for m in mutations:
        if m.name in seen:
            die("%s:%d: `%s` is also at line %d"
                % (path, m.line, m.name, seen[m.name]))
        seen[m.name] = m.line
        if m.check not in CHECKS:
            die("%s:%d: `%s` names no check `%s`"
                % (path, m.line, m.name, m.check))
        # A mutation to a file its check does not build would run a clean
        # design and be reported as caught or survived on no evidence.
        if m.path not in CHECKS[m.check]["sources"]:
            die("%s:%d: `%s` mutates %s, which `%s` does not build"
                % (path, m.line, m.name, m.path, m.check))
        if not m.old.strip():
            die("%s:%d: `%s` has an empty @old" % (path, m.line, m.name))
        if m.old == m.new:
            die("%s:%d: `%s` changes nothing" % (path, m.line, m.name))
    return mutations


def die(msg):
    sys.stderr.write("mutations: %s\n" % msg)
    sys.exit(2)


def copy_tree(dest):
    """A private rtl/ and tb/ to mutate.  Never the working tree."""
    if os.path.exists(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    for d in ("rtl", "tb"):
        shutil.copytree(os.path.join(REPO, d), os.path.join(dest, d))


def apply(work, m, listing):
    """Put the mutation in.  Exactly one occurrence, or it is a failure.

    Nothing about a mutation that did not apply is visible later --- the build
    is clean and the check passes --- so this is the one place it can be
    caught, and it is fatal rather than skipped.
    """
    path = os.path.join(work, m.path)
    with open(path) as f:
        src = f.read()
    n = src.count(m.old)
    if n != 1:
        return ("%s:%d: `%s` matches %s %d times, want exactly once"
                % (listing, m.line, m.name, m.path, n))
    with open(path, "w") as f:
        f.write(src.replace(m.old, m.new))
    return None


def run(cmd, cwd):
    p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT)
    out = p.communicate()[0].decode("utf-8", "replace")
    return p.returncode, out


def first_problem(out):
    """The one line of a build or check failure worth putting in the table."""
    for line in out.split("\n"):
        s = line.strip()
        if s.startswith("%Error") or s.startswith("%Warning") or \
           s.startswith("FAIL") or s.startswith("tick ") or \
           s.startswith("boards="):
            return s
    for line in out.split("\n"):
        if line.strip():
            return line.strip()
    return "(no output)"


def build_and_run(args, work, check):
    """Verilate the check in `work` and run it.  Returns a verdict."""
    spec = CHECKS[check]
    if check == "cables":
        return cables_check(args, work)

    obj = os.path.join(work, "obj_" + check)
    cmd = [args.verilator, "--cc", "--exe", "--build", "-Wall"]
    cmd += spec["flags"]
    cmd += ["-Mdir", obj, "--top-module", spec["top"]]
    cmd += spec["sources"]
    cmd += [os.path.join(work, spec["tb"])]
    rc, out = run(cmd, work)
    if rc != 0:
        return BROKEN, first_problem(out)

    cmd = [os.path.join(obj, "V" + spec["top"])]
    if spec["golden"]:
        cmd.append(os.path.join(args.goldens, spec["golden"]))
    rc, out = run(cmd, work)
    if rc != 0:
        return CAUGHT, first_problem(out)
    return SURVIVED, out.strip().split("\n")[0]


def cables_check(args, work):
    """The cables check is two targets, and it takes both to hold the claim.

    `cables.pass` is lint alone, which catches a wrong direction or a name
    that no longer exists.  It cannot catch a changed comment --- MIT's own
    name on the wire --- and CLAUDE.md says what cadr_cables.svh holds to is
    both netlists via `part::pinout`.  Only `current` enforces that: it
    regenerates from muir and fails if anything moved.  So this does the same,
    against the copy, with plain diff standing in for `git diff`.
    """
    cmd = [args.verilator, "--lint-only", "-Wall",
           "--top-module", "cadr_cables_lint", "-Irtl",
           "rtl/cadr_cables_lint.sv"]
    rc, out = run(cmd, work)
    if rc != 0:
        return CAUGHT, first_problem(out)

    # `current`, on the copy: keep what the mutation made, regenerate over it,
    # and see whether the generator disagrees.
    mutated = os.path.join(work, "mutated")
    if os.path.exists(mutated):
        shutil.rmtree(mutated)
    os.makedirs(mutated)
    for path in GENERATED:
        shutil.copy(os.path.join(work, path),
                    os.path.join(mutated, os.path.basename(path)))

    cmd = [args.cargo, "run", "--quiet", "--manifest-path",
           os.path.join(REPO, "golden", "Cargo.toml"), "--bin", "cables"]
    rc, out = run(cmd, work)
    if rc != 0:
        return BROKEN, "the generator failed: " + first_problem(out)

    for path in GENERATED:
        base = os.path.basename(path)
        if not filecmp.cmp(os.path.join(work, path),
                           os.path.join(mutated, base), shallow=False):
            return CAUGHT, "`current`: %s is not what the generator writes" % base
    return SURVIVED, "lint passes and the generator writes it unchanged"


def check_makefile():
    """The Makefile is the other description of the six checks.

    Two descriptions of one thing drift.  This does not reimplement the
    Makefile --- it only asks that every source file this runner verilates is
    named in the rule that builds the same check, so a file added to a check
    there and not here shows up as a warning rather than as silent
    under-testing.
    """
    try:
        with open(os.path.join(REPO, "Makefile")) as f:
            text = f.read()
    except IOError:
        return ["Makefile is not readable"]
    missing = []
    for check, spec in sorted(CHECKS.items()):
        for src in spec["sources"]:
            if src not in text:
                missing.append("%s: the Makefile does not mention %s"
                               % (check, src))
    return missing


def main():
    ap = argparse.ArgumentParser(description="mutation-test the checks")
    ap.add_argument("--goldens", required=True,
                    help="directory holding the reference traces")
    ap.add_argument("--work", required=True,
                    help="where the per-mutation copies go")
    ap.add_argument("--verilator", default="verilator")
    ap.add_argument("--cargo", default="cargo")
    ap.add_argument("--jobs", type=int, default=0,
                    help="parallel mutations (default: one per cpu)")
    ap.add_argument("--only", default=None,
                    help="run only mutations whose name or check contains this")
    # Not for everyday use: `make mutants` runs list.txt. It is here so that
    # the runner's own guarantees --- a mutation that does not apply, and one
    # lint rejects, are loud --- can be demonstrated against a list written to
    # fail, rather than only asserted in a comment.
    ap.add_argument("--list", default=LIST, help="a list other than list.txt")
    args = ap.parse_args()

    if args.jobs <= 0:
        # `or 4`: cpu_count() answers None where it cannot tell.
        args.jobs = os.cpu_count() or 4

    mutations = parse(args.list)
    if args.only:
        mutations = [m for m in mutations
                     if args.only in m.name or args.only in m.check]
        if not mutations:
            die("--only %s matches nothing" % args.only)

    for warning in check_makefile():
        sys.stderr.write("mutations: warning: %s\n" % warning)

    # Only the checks that have mutations against them, so `--only` does not
    # pay for the rest.
    wanted = sorted(set(m.check for m in mutations))
    for check in wanted:
        golden = CHECKS[check]["golden"]
        if golden and not os.path.exists(os.path.join(args.goldens, golden)):
            die("%s: no such trace; `make %s/%s` first"
                % (os.path.join(args.goldens, golden), args.goldens, golden))

    if not os.path.exists(args.work):
        os.makedirs(args.work)

    # The baseline.  A check that was already failing would call every
    # mutation caught, so nothing runs until the unmutated copy is clean.
    sys.stdout.write("baseline, on an unmutated copy:\n")
    base = os.path.join(args.work, "baseline")
    copy_tree(base)
    baseline_bad = False
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = dict((pool.submit(build_and_run, args, base, c), c)
                       for c in wanted)
        for f in concurrent.futures.as_completed(futures):
            check = futures[f]
            verdict, detail = f.result()
            # SURVIVED here means the check passed on unmutated source, which
            # is what it is supposed to do.
            ok = verdict == SURVIVED
            sys.stdout.write("  %-14s %s\n"
                             % (check, "ok" if ok else "FAILED: " + detail))
            baseline_bad = baseline_bad or not ok
    if baseline_bad:
        sys.stderr.write(
            "\nmutations: the baseline does not pass, so nothing was run.\n"
            "  Fix the checks first: a mutation `caught` by a check that was\n"
            "  already failing is caught by nothing.\n")
        return 2
    sys.stdout.write("\n")

    def one(m):
        work = os.path.join(args.work, m.name)
        copy_tree(work)
        problem = apply(work, m, args.list)
        if problem:
            m.verdict, m.detail = UNAPPLIED, problem
            return m
        m.verdict, m.detail = build_and_run(args, work, m.check)
        # A survivor is a finding, and the first question about it is whether
        # anything else would have caught it.  Only survivors pay for this.
        if m.verdict == SURVIVED:
            for other in sorted(CHECKS):
                if other == m.check or m.path not in CHECKS[other]["sources"]:
                    continue
                golden = CHECKS[other]["golden"]
                if golden and not os.path.exists(
                        os.path.join(args.goldens, golden)):
                    continue
                verdict, _ = build_and_run(args, work, other)
                if verdict == SURVIVED:
                    m.also.append(other)
        return m

    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        done = 0
        for m in pool.map(one, mutations):
            done += 1
            mark = {CAUGHT: ".", SURVIVED: "S",
                    BROKEN: "B", UNAPPLIED: "U"}[m.verdict]
            sys.stdout.write(mark)
            sys.stdout.flush()
        sys.stdout.write("\n\n")

    return report(mutations)


def report(mutations):
    counts = {}
    for m in mutations:
        row = counts.setdefault(m.check, {CAUGHT: 0, SURVIVED: 0,
                                          BROKEN: 0, UNAPPLIED: 0})
        row[m.verdict] += 1

    sys.stdout.write("  %-14s %9s %7s %9s %7s %10s\n"
                     % ("check", "mutations", "caught", "survived", "broken",
                        "unapplied"))
    total = {CAUGHT: 0, SURVIVED: 0, BROKEN: 0, UNAPPLIED: 0}
    for check in sorted(counts):
        row = counts[check]
        n = sum(row.values())
        sys.stdout.write("  %-14s %9d %7d %9d %7d %10d\n"
                         % (check, n, row[CAUGHT], row[SURVIVED],
                            row[BROKEN], row[UNAPPLIED]))
        for k in total:
            total[k] += row[k]
    sys.stdout.write("  %-14s %9d %7d %9d %7d %10d\n"
                     % ("total", sum(total.values()), total[CAUGHT],
                        total[SURVIVED], total[BROKEN], total[UNAPPLIED]))

    for verdict, heading, why in (
        (UNAPPLIED, "DID NOT APPLY",
         "The source moved under the list.  Nothing was tested; these are not\n"
         "  survivors and not caught.  Fix the @old text."),
        (BROKEN, "DID NOT BUILD",
         "Lint rejected the mutation, so the check never saw it.  Rewrite it\n"
         "  to keep every signal used, or lint is doing the catching."),
        (SURVIVED, "SURVIVED",
         "A hole in a check: the design is wrong and the check says it is\n"
         "  fine.  This belongs in the check, not in the list."),
    ):
        bad = [m for m in mutations if m.verdict == verdict]
        if not bad:
            continue
        sys.stdout.write("\n%s\n  %s\n\n" % (heading, why))
        for m in bad:
            sys.stdout.write("  %s  (%s, %s)\n" % (m.name, m.check, m.path))
            for note in m.notes:
                sys.stdout.write("      %s\n" % note)
            sys.stdout.write("      %s\n" % m.detail)
            if m.also:
                sys.stdout.write("      not caught by %s either\n"
                                 % ", ".join(m.also))

    if total[CAUGHT] == sum(total.values()):
        sys.stdout.write("\nok: every mutation was caught by its check\n")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
