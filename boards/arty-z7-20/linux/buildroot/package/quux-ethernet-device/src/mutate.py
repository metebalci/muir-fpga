#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The mutation runner for quux-ethernet-device: bugs the check has to catch.
#
# The same runner as cadr-terminal's, one package along, and the record
# format is `mutations/list.txt`'s: literal text, no line numbers, and an
# `@old` that does not match exactly once fails the run rather than being
# skipped.  A record that does not build is BROKEN, not caught.
#
# What a mutant is judged by is the whole check: `qed_compare.py` over every
# script against muir's side, kept from the check's own run in `--reference`
# (muir's answers do not change with a mutant of this program), the flags'
# answers, the checksum vectors, then the unit checks.  A mutant is caught
# when that fails.
#
#     mutate.py --list qed_mutations.txt --work DIR --golden G --vectors V --reference R
#               [--only NAME]

import argparse
import os
import shutil
import subprocess
import sys

CORE = ["qed_offload.c", "qed_host.c", "qed_mem.c", "qed_ring.c", "qed_face_fabric.c", "qed_tap.c"]
HEADERS = ["qed_offload.h", "qed_host.h", "qed_mem.h", "qed_ring.h", "qed_face.h", "qed_tap.h"]
JUDGE = ["qed_test.c", "qed_compare.py", "qed_scenarios.py", "qed_flags.txt"]
SOURCES = CORE + HEADERS + JUDGE + ["quux-ethernet-device.c"]


def parse(path):
    """The records, in order.  A malformed one is fatal, not skipped."""
    records, r, field, lines = [], None, None, []

    def close_field():
        nonlocal field, lines
        if field:
            r[field] = "".join(lines)
        field, lines = None, []

    for n, line in enumerate(open(path), 1):
        if field and not line.startswith("@"):
            lines.append(line)
            continue
        bare = line.rstrip("\n")
        if not bare.startswith("@"):
            if bare.strip() and not bare.lstrip().startswith("#"):
                sys.exit(f"{path}:{n}: text outside a record: {bare}")
            continue
        key, _, rest = bare[1:].partition(" ")
        rest = rest.strip()
        if key == "mutation":
            close_field()
            if r:
                records.append(r)
            r = {"mutation": rest, "note": []}
        elif r is None:
            sys.exit(f"{path}:{n}: @{key} before any @mutation")
        elif key in ("file", "why"):
            close_field()
            r[key] = rest
        elif key == "note":
            close_field()
            r["note"].append(rest)
        elif key in ("old", "new"):
            close_field()
            field = key
        elif key == "end":
            close_field()
        else:
            sys.exit(f"{path}:{n}: @{key} is not a field of a record")
    close_field()
    if r:
        records.append(r)
    names = set()
    for r in records:
        for k in ("file", "why", "old"):
            if k not in r:
                sys.exit(f"{r['mutation']}: no @{k}")
        if r["mutation"] in names:
            sys.exit(f"{r['mutation']}: two records of one name")
        names.add(r["mutation"])
        r.setdefault("new", "")
    return records


def apply(record, work, src):
    """A copy of the sources with the record applied, or a reason it cannot be."""
    here = os.path.join(work, record["mutation"])
    if os.path.exists(here):
        subprocess.run(["chmod", "-R", "u+rwx", here])
    shutil.rmtree(here, ignore_errors=True)
    os.makedirs(here)
    for f in SOURCES:
        shutil.copy(os.path.join(src, f), os.path.join(here, f))
    named = record["file"]
    target = os.path.join(here, named)
    if named == "quux-ethernet-device.c":
        return here, (f"@file {named} is a program's start, which no check compiles; a record "
                      "aimed at it would survive by construction")
    if named not in SOURCES or named in JUDGE:
        return here, (f"@file {named} is not one of the program's sources; a record aimed "
                      "at the check itself would be caught by breaking the judge")
    text = open(target).read()
    hits = text.count(record["old"])
    if hits != 1:
        return here, (f"@old matches {hits} times in {named}; a record names its lines "
                      "exactly once or it has rotted")
    open(target, "w").write(text.replace(record["old"], record["new"]))
    return here, None


def build_and_run(here, cc, cflags, golden, vectors, reference):
    binary = os.path.join(here, "qed_test")
    cmd = [cc] + cflags.split() + ["-DQED_TEST_HOOKS", "-o", binary, os.path.join(here, "qed_test.c")] \
        + [os.path.join(here, f) for f in CORE]
    build = subprocess.run(cmd, capture_output=True, text=True)
    if build.returncode != 0:
        return None, build.stderr.strip().splitlines()[:6]
    try:
        run = subprocess.run([sys.executable, os.path.join(here, "qed_compare.py"), "--golden", golden,
                              "--test", binary, "--vectors", vectors,
                              "--flags", os.path.join(here, "qed_flags.txt"),
                              "--work", os.path.join(here, "compare"),
                              "--reference", reference, "--quiet"],
                             capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        # A check that never finishes is a check that did not pass.
        run = subprocess.CompletedProcess([], 1, "FAIL: the check did not finish in 300 s", "")
    return run, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--golden", required=True)
    ap.add_argument("--vectors", required=True)
    ap.add_argument("--reference", required=True)
    ap.add_argument("--only")
    ap.add_argument("--cc", default="cc")
    ap.add_argument("--cflags", default="-O1 -g -Wall -Wextra -std=gnu11")
    args = ap.parse_args()

    if not os.path.exists(os.path.join(args.reference, ".whole")):
        sys.exit(f"mutations: {args.reference} holds no whole run of muir's side; run the check first")
    src = os.path.dirname(os.path.abspath(args.list))
    os.makedirs(args.work, exist_ok=True)
    records = parse(args.list)
    if args.only:
        records = [r for r in records if r["mutation"] == args.only]
        if not records:
            sys.exit(f"no record named {args.only}")

    print(f"mutations: {len(records)} records, from {os.path.basename(args.list)}")
    caught = survived = broken = 0
    for r in records:
        here, why = apply(r, args.work, src)
        if why:
            print(f"  BROKEN    {r['mutation']}\n              {why}")
            broken += 1
            continue
        run, build_error = build_and_run(here, args.cc, args.cflags, args.golden, args.vectors,
                                         args.reference)
        if build_error:
            print(f"  BROKEN    {r['mutation']}: it does not compile")
            for line in build_error:
                print(f"              {line}")
            broken += 1
            continue
        if run.returncode != 0:
            first = next((l for l in run.stdout.splitlines() + run.stderr.splitlines()
                          if "FAIL" in l), "(no FAIL line, but it failed)")
            print(f"  caught    {r['mutation']}")
            print(f"              {first.strip()[:160]}")
            caught += 1
        else:
            print(f"  SURVIVED  {r['mutation']}")
            print(f"              it should have been caught: {r['why']}")
            for n in r["note"]:
                print(f"              {n}")
            survived += 1
        subprocess.run(["chmod", "-R", "u+rwx", here])
        shutil.rmtree(here, ignore_errors=True)
    print(f"mutations: {caught} caught, {survived} survived, {broken} broken")
    sys.exit(1 if survived or broken else 0)


if __name__ == "__main__":
    main()
