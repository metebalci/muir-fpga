#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The mutation runner for cadr-terminal: bugs `screen_test.c` has to catch.
#
# `mutations/run.py` at the repository root does this for the fabric, and this
# is the same idea one program along, in the package rather than in the
# top-level Makefile --- the disk pack program's check is in its own package
# too, and this slice touches nothing outside its own directory.  The record
# format is `mutations/list.txt`'s, on purpose: literal text, no line numbers
# and no context, so a record rots only when the lines it names change, and an
# `@old` that does not match exactly once fails the run rather than being
# quietly skipped.
#
# THE BUILD FAILING IS NOT A MUTATION SURVIVING AND NOT A MUTATION CAUGHT.
# CLAUDE.md records that two mutations of the fabric were reported as
# surviving when they had never been built: lint rejected them and a stale
# binary ran.  So each record is built in a directory of its own, a build that
# fails is BROKEN, and BROKEN fails the run.
#
#     mutate.py --list screen_mutations.txt --work DIR [--only NAME] [--screens DIR]

import argparse
import os
import shutil
import subprocess
import sys

CORE = ["screen_frame.c", "screen_rfb.c", "screen_server.c"]
HEADERS = ["screen_geom.h", "screen_frame.h", "screen_rfb.h", "screen_server.h"]
COMMON = ["cadr_log.c", "cadr_mem.c"]


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
    for r in records:
        for k in ("file", "why", "old"):
            if k not in r:
                sys.exit(f"{r['mutation']}: no @{k}")
        r.setdefault("new", "")
    return records


def apply(record, work, src, common):
    """A copy of the sources with the record applied, or a reason it cannot be."""
    here = os.path.join(work, record["mutation"])
    shutil.rmtree(here, ignore_errors=True)
    os.makedirs(os.path.join(here, "cadr-terminal", "src"))
    os.makedirs(os.path.join(here, "cadr-common", "src", "cadr"))
    for f in CORE + HEADERS + ["screen_test.c", "cadr-terminal.c"]:
        shutil.copy(os.path.join(src, f), os.path.join(here, "cadr-terminal", "src", f))
    for f in COMMON:
        shutil.copy(os.path.join(common, f), os.path.join(here, "cadr-common", "src", f))
    for f in ("cadr_log.h", "cadr_mem.h"):
        shutil.copy(os.path.join(common, "cadr", f),
                    os.path.join(here, "cadr-common", "src", "cadr", f))
    target = os.path.join(here, "cadr-terminal", "src", record["file"])
    if not os.path.exists(target):
        return here, f"@file {record['file']} is not one of this package's sources"
    text = open(target).read()
    hits = text.count(record["old"])
    if hits != 1:
        return here, (f"@old matches {hits} times in {record['file']}; a record names its "
                      "lines exactly once or it has rotted")
    open(target, "w").write(text.replace(record["old"], record["new"]))
    return here, None


def build_and_run(here, cc, cflags, screens):
    src = os.path.join(here, "cadr-terminal", "src")
    common = os.path.join(here, "cadr-common", "src")
    binary = os.path.join(here, "screen_test")
    cmd = ([cc] + cflags.split() + ["-I" + common, "-o", binary,
            os.path.join(src, "screen_test.c")]
           + [os.path.join(src, f) for f in CORE]
           + [os.path.join(common, f) for f in COMMON])
    build = subprocess.run(cmd, capture_output=True, text=True)
    if build.returncode != 0:
        return None, build.stderr.strip().splitlines()[:6]
    run = subprocess.run([binary, "--screens", screens,
                          "--server-log", os.path.join(here, "server.log")],
                         capture_output=True, text=True, timeout=900)
    return run, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--only")
    ap.add_argument("--screens", default="")
    ap.add_argument("--cc", default="cc")
    ap.add_argument("--cflags", default="-O2 -Wall -Wextra -std=gnu11")
    args = ap.parse_args()

    src = os.path.dirname(os.path.abspath(args.list))
    common = os.path.abspath(os.path.join(src, "..", "..", "cadr-common", "src"))
    os.makedirs(args.work, exist_ok=True)
    records = parse(args.list)
    if args.only:
        records = [r for r in records if r["mutation"] == args.only]
        if not records:
            sys.exit(f"no record named {args.only}")

    print(f"mutations: {len(records)} records, from {os.path.basename(args.list)}")
    caught = survived = broken = 0
    for r in records:
        here, why = apply(r, args.work, src, common)
        if why:
            print(f"  BROKEN    {r['mutation']}\n              {why}")
            broken += 1
            continue
        run, build_error = build_and_run(here, args.cc, args.cflags, args.screens)
        if build_error:
            print(f"  BROKEN    {r['mutation']}: it does not compile")
            for line in build_error:
                print(f"              {line}")
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
