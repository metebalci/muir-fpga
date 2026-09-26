#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# quux-file-device against muir's own file device.
#
#     qfd_compare.py --golden G --test T --work W [--reference R] [--quiet]
#
# For every script in `qfd_scenarios.py`: its folder is built once and
# copied twice; muir's device (G, `golden/src/quux_file_device.rs`) runs the
# script over one copy and this program (T, `qfd_test`) over the other; and
# the two transcripts must be the same bytes, and the two folders after the
# same names, kinds, permissions, contents, times and link targets.  Then the
# status of every errno, the same way; then T's own unit checks.
#
# **AND THE SCRIPTS MUST STILL REACH WHAT THEY ARE FOR.**  Agreement over
# scripts that produce nothing is agreement about nothing, so muir's
# transcripts are counted: every opcode, and every status but the two no
# Linux folder of the build host produces on its own (NMR, the host full, and
# DAT, its I/O error, which `qfd_test --unit` gives through its hooks), must
# have been answered at least once.
#
# `--reference R` keeps muir's side --- its transcripts, folders and errno
# table --- in R, and reuses them when they are there, which is what
# `mutate.py` does: muir's answers do not change with a mutant of this
# program.  The check itself always writes a fresh one.

import argparse
import hashlib
import os
import shutil
import stat
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qfd_scenarios  # noqa: E402

STATUS_NAMES = {0: "OK", 1: "FNF", 2: "DNF", 3: "FAE", 4: "REF", 5: "ACC", 6: "ATF", 7: "DAE",
                8: "DNE", 9: "NMR", 10: "IOD", 11: "WKF", 12: "IPS", 13: "NER", 14: "UOP",
                15: "DAT", 16: "FOR", 17: "RAD", 64: "bad handle", 65: "bad buffer",
                66: "bad argument"}
NOT_FROM_A_FOLDER = {9, 15}


def manifest(root):
    """Every name under `root`: kind, permissions, size, content, time, target."""
    out = []
    for d, dirs, files in os.walk(root):
        dirs.sort()
        for n in sorted(dirs + files):
            p = os.path.join(d, n)
            st = os.lstat(p)
            rel = repr(os.path.relpath(p, root))
            mode = stat.S_IMODE(st.st_mode)
            if stat.S_ISLNK(st.st_mode):
                out.append(f"{rel} link {os.readlink(p)!r}")
            elif stat.S_ISDIR(st.st_mode):
                out.append(f"{rel} dir {mode:o} {int(st.st_mtime)}")
            elif stat.S_ISREG(st.st_mode):
                if st.st_size > (64 << 20):
                    digest = "not read"
                else:
                    with open(p, "rb") as f:
                        digest = hashlib.sha256(f.read()).hexdigest()
                out.append(f"{rel} file {mode:o} {st.st_size} {int(st.st_mtime)} {digest}")
            else:
                out.append(f"{rel} other {stat.S_IFMT(st.st_mode):o} {mode:o}")
    return "\n".join(out) + "\n"


def run(cmd, log):
    with open(log, "w") as f:
        try:
            r = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, timeout=120)
        except subprocess.TimeoutExpired:
            f.write("FAIL: it did not finish in 120 s\n")
            return 1
    return r.returncode


def tally(transcript, ops, statuses):
    for line in open(transcript):
        w = line.split()
        if w and w[0] == "resp":
            w0 = int(w[2], 16)
            statuses.add((w0 >> 16) & 0xFF)
            ops.add((w0 >> 24) & 0xFF)


def first_difference(a, b):
    la, lb = open(a).read().splitlines(), open(b).read().splitlines()
    for k, (x, y) in enumerate(zip(la, lb)):
        if x != y:
            return k + 1, x[:300], y[:300]
    k = min(len(la), len(lb))
    return k + 1, (la[k][:300] if k < len(la) else "(end)"), (lb[k][:300] if k < len(lb) else "(end)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--golden", required=True)
    ap.add_argument("--test", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--reference")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()
    work = os.path.abspath(args.work)
    ref = os.path.abspath(args.reference) if args.reference else os.path.join(work, "reference")
    reuse = bool(args.reference) and os.path.exists(os.path.join(ref, ".whole"))
    if not reuse:
        shutil.rmtree(ref, ignore_errors=True)
        os.makedirs(ref)
    for d in ("ours", "seed"):
        path = os.path.join(work, d)
        if os.path.exists(path):
            subprocess.run(["chmod", "-R", "u+rwx", path])
        shutil.rmtree(path, ignore_errors=True)
        os.makedirs(path)
    bad = 0
    say = (lambda *a: None) if args.quiet else print
    ops, statuses = set(), set()

    for make in qfd_scenarios.ALL:
        s = make()
        seed = os.path.join(work, "seed", s.name)
        s.build(seed)
        script = os.path.join(work, "seed", s.name + ".script")
        open(script, "w").write(s.text())
        muir_t = os.path.join(ref, s.name + ".transcript")
        muir_m = os.path.join(ref, s.name + ".manifest")
        if not reuse:
            tree = os.path.join(ref, s.name)
            subprocess.run(["cp", "-a", seed, tree], check=True)
            if run([args.golden, "--script", script, "--tree", tree, "--out", muir_t],
                   os.path.join(ref, s.name + ".log")) != 0:
                print(f"compare: {s.name}: muir's device did not run the script; its log is "
                      f"{os.path.join(ref, s.name + '.log')}")
                return 1
            open(muir_m, "w").write(manifest(tree))
        tally(muir_t, ops, statuses)
        tree = os.path.join(work, "ours", s.name)
        subprocess.run(["cp", "-a", seed, tree], check=True)
        ours_t = os.path.join(work, "ours", s.name + ".transcript")
        log = os.path.join(work, "ours", s.name + ".log")
        rc = run([args.test, "--script", script, "--tree", tree, "--out", ours_t], log)
        fails = [l for l in open(log) if l.startswith("FAIL:")]
        if rc != 0 or fails:
            print(f"FAIL: {s.name}: the program broke a rule of the page while it ran:")
            for l in (fails or ["(no FAIL line; exit %d)\n" % rc])[:5]:
                print("    " + l.rstrip())
            bad += 1
            continue
        if open(ours_t, "rb").read() != open(muir_t, "rb").read():
            k, x, y = first_difference(muir_t, ours_t)
            print(f"FAIL: {s.name}: the transcript differs from muir's at line {k}:")
            print(f"    muir: {x}")
            print(f"    ours: {y}")
            bad += 1
            continue
        mine = manifest(tree)
        if mine != open(muir_m).read():
            print(f"FAIL: {s.name}: the folder after differs from muir's:")
            for l in sorted(set(open(muir_m).read().splitlines()) ^ set(mine.splitlines()))[:8]:
                print("    " + ("muir: " if l in open(muir_m).read().splitlines() else "ours: ") + l)
            bad += 1
            continue
        n = sum(1 for l in open(muir_t) if l.startswith("resp "))
        say(f"compare: {s.name}: {n} responses and the folder after, the same as muir's")

    # The errno table.
    muir_e = os.path.join(ref, "errno.table")
    if not reuse:
        with open(muir_e, "w") as f:
            subprocess.run([args.golden, "--errno-table"], stdout=f, check=True)
    ours_e = os.path.join(work, "ours", "errno.table")
    with open(ours_e, "w") as f:
        subprocess.run([args.test, "--errno-table"], stdout=f)
    if open(ours_e).read() != open(muir_e).read():
        k, x, y = first_difference(muir_e, ours_e)
        print(f"FAIL: the status of errno differs from muir's at line {k}: muir {x!r}, ours {y!r}")
        bad += 1
    else:
        say("compare: the status of every errno from 1 to 133, the same as muir's")

    # What the scripts reached.
    want = set(STATUS_NAMES) - NOT_FROM_A_FOLDER
    if want - statuses:
        print("FAIL: the scripts no longer produce, on muir: "
              + ", ".join(STATUS_NAMES[k] for k in sorted(want - statuses)))
        bad += 1
    if set(range(0, 11)) - ops:
        print("FAIL: the scripts no longer send opcodes " + ", ".join(map(str, sorted(set(range(0, 11)) - ops))))
        bad += 1
    say(f"compare: muir answered every opcode and {len(statuses)} statuses; "
        f"not from a folder: {', '.join(STATUS_NAMES[k] for k in sorted(NOT_FROM_A_FOLDER))}")

    # The unit checks.
    unit = os.path.join(work, "unit")
    if os.path.exists(unit):
        subprocess.run(["chmod", "-R", "u+rwx", unit])
    shutil.rmtree(unit, ignore_errors=True)
    os.makedirs(unit)
    r = subprocess.run([args.test, "--unit", "--work", unit], capture_output=True, text=True)
    for l in r.stdout.splitlines():
        if l.startswith("FAIL:") or not args.quiet:
            print(l)
    if r.returncode != 0:
        bad += 1
    if not reuse:
        open(os.path.join(ref, ".whole"), "w").write("muir's side is whole\n")
    print(f"compare: {'FAILED, ' + str(bad) + ' failing' if bad else 'ok'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
