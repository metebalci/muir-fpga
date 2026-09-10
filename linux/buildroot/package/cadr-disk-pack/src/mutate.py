#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The mutation runner for cadr-disk-pack: bugs `feeder_test.c` has to catch.
#
# `mutations/run.py` at the repository root does this for the fabric, and this
# is the same idea one program along, in the package rather than in the
# top-level Makefile --- `make -C src mutants` is the entry point and this
# slice touches nothing outside its own directory.  The record format is
# `mutations/list.txt`'s, on purpose: literal text, no line numbers and no
# context, so a record rots only when the lines it names change, and an
# `@old` that does not match exactly once fails the run rather than being
# quietly skipped.
#
# THE BUILD FAILING IS NOT A MUTATION SURVIVING AND NOT A MUTATION CAUGHT.
# CLAUDE.md records that two mutations of the fabric were reported as
# surviving when they had never been built: lint rejected them and a stale
# binary ran.  So each record is built in a directory of its own, a build that
# fails is BROKEN, and BROKEN fails the run.
#
# AND A MUTATION IN A FILE THE CHECK DOES NOT BUILD IS NOT A MUTATION EITHER.
# `feeder_test.c` links the core and nothing else --- `cadr-disk-pack.c` is
# the program's main and is never built here --- so a record naming it would
# be applied, built around, and reported as surviving on evidence that does
# not exist.  `@file` must be one of the core sources or headers below, and a
# record naming anything else is BROKEN.
#
#     mutate.py --list pack_mutations.txt --work DIR --golden build/disk.golden [--only NAME]

import argparse
import os
import shutil
import subprocess
import sys

CORE = ["pack_file.c", "pack_bay.c", "pack_side.c", "pack_feeder.c"]
HEADERS = ["pack_ecc.h", "pack_file.h", "pack_bay.h", "pack_side.h", "pack_feeder.h"]
MUTABLE = set(CORE) | set(HEADERS)


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
    seen = set()
    for r in records:
        for k in ("file", "why", "old"):
            if k not in r:
                sys.exit(f"{r['mutation']}: no @{k}")
        if r["mutation"] in seen:
            sys.exit(f"{r['mutation']}: two records of that name")
        seen.add(r["mutation"])
        r.setdefault("new", "")
    return records


def apply(record, work, src):
    """A copy of the sources with the record applied, or a reason it cannot be."""
    here = os.path.join(work, record["mutation"])
    shutil.rmtree(here, ignore_errors=True)
    os.makedirs(os.path.join(here, "src"))
    for f in CORE + HEADERS + ["feeder_test.c"]:
        shutil.copy(os.path.join(src, f), os.path.join(here, "src", f))
    if record["file"] not in MUTABLE:
        return here, (f"@file {record['file']} is not one of the sources the check builds; "
                      "a mutation there would be reported on evidence that does not exist")
    target = os.path.join(here, "src", record["file"])
    text = open(target).read()
    hits = text.count(record["old"])
    if hits != 1:
        return here, (f"@old matches {hits} times in {record['file']}; a record names its "
                      "lines exactly once or it has rotted")
    open(target, "w").write(text.replace(record["old"], record["new"]))
    return here, None


def build_and_run(here, cc, cflags, golden):
    src = os.path.join(here, "src")
    binary = os.path.join(here, "feeder_test")
    cmd = ([cc] + cflags.split() + ["-o", binary, os.path.join(src, "feeder_test.c")]
           + [os.path.join(src, f) for f in CORE])
    build = subprocess.run(cmd, capture_output=True, text=True)
    if build.returncode != 0:
        return None, build.stderr.strip().splitlines()[:6]
    work = os.path.join(here, "run")
    os.makedirs(work, exist_ok=True)
    try:
        run = subprocess.run([binary, golden, work], capture_output=True, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        return "timeout", None
    return run, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--golden", required=True)
    ap.add_argument("--only")
    ap.add_argument("--cc", default="cc")
    ap.add_argument("--cflags", default="-O2 -Wall -Wextra -std=gnu11")
    args = ap.parse_args()

    if not os.path.exists(args.golden):
        sys.exit(f"no {args.golden}: run 'make disk-golden' at the repository root")
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
        run, build_error = build_and_run(here, args.cc, args.cflags, os.path.abspath(args.golden))
        if build_error:
            print(f"  BROKEN    {r['mutation']}: it does not compile")
            for line in build_error:
                print(f"              {line}")
            broken += 1
            continue
        if run == "timeout":
            # A check that hangs is a check that did not run.  It is not a
            # catch: an exit code nobody saw says nothing.
            print(f"  BROKEN    {r['mutation']}: the check did not finish inside 900 s")
            broken += 1
            continue
        if run.returncode != 0:
            first = next((l for l in run.stdout.splitlines() + run.stderr.splitlines()
                          if "FAIL:" in l), "(no FAIL line, but it failed)")
            print(f"  caught    {r['mutation']}")
            print(f"              {first.strip()}")
            caught += 1
        else:
            print(f"  SURVIVED  {r['mutation']}")
            print(f"              it should have been caught: {r['why']}")
            for n in r["note"]:
                print(f"              {n}")
            survived += 1
    print(f"mutations: {caught} caught, {survived} survived, {broken} broken")
    sys.exit(1 if survived or broken else 0)


if __name__ == "__main__":
    main()
