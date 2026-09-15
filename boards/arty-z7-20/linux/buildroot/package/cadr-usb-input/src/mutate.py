#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The mutation runner for cadr-usb-input: bugs `usb_test.c` has to catch.
#
# `mutations/run.py` at the repository root does this for the fabric, and this
# is the same idea one program along, in the package rather than in the
# top-level Makefile --- the disk pack program's check, the screen's and the
# serial line's are in their own packages too.  The record format is
# `mutations/list.txt`'s, on purpose: literal text, no line numbers and no
# context, so a record rots only when the lines it names change, and an `@old`
# that does not match exactly once fails the run rather than being quietly
# skipped.
#
# THE BUILD FAILING IS NOT A MUTATION SURVIVING AND NOT A MUTATION CAUGHT.
# Two mutations of the fabric were once reported as surviving when they had
# never been built: lint rejected them and a stale binary ran.  So each record
# is built in a directory of its own, a build that fails is BROKEN, and BROKEN
# fails the run.
#
# **THIS ONE MUTATES THREE PACKAGES, BECAUSE THE CHECK BUILDS THREE.**  A key
# from the board's keyboard goes through this package, over the link in
# cadr-common, and into the screen's own server, which maps it and paces it.
# The whole of that is under check here, so a record may be aimed anywhere in
# it: `@file usb_keys.c` is this package's, and `@file
# cadr-terminal/src/screen_server.c` or `@file cadr-common/src/cadr_input_link.c`
# are the other two.  A record aimed at a file the check does not build is
# BROKEN and says so, rather than surviving for ever.
#
#     mutate.py --list usb_mutations.txt --work DIR [--only NAME]

import argparse
import os
import shutil
import subprocess
import sys

# This package: what the check builds of it, and its headers.
CORE = ["usb_keys.c", "usb_devices.c"]
HEADERS = ["usb_keys.h", "usb_devices.h", "usb_keymap.h"]
# The screen's package: the far half of the road, built here for the host
# check and not by this package's target build.
TERMINAL = ["input_face.c", "input_keys.c", "input_mapping.c",
            "screen_server.c", "screen_frame.c", "screen_rfb.c"]
TERMINAL_HEADERS = ["input_face.h", "input_keys.h", "input_keymap.h",
                    "input_mapping.h", "screen_server.h", "screen_frame.h",
                    "screen_rfb.h", "screen_geom.h"]
COMMON = ["cadr_log.c", "cadr_mem.c", "cadr_input_link.c"]
COMMON_HEADERS = ["cadr_log.h", "cadr_mem.h", "cadr_input_link.h"]


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


def apply(record, work, src, common, terminal):
    """A copy of the sources with the record applied, or a reason it cannot be."""
    here = os.path.join(work, record["mutation"])
    shutil.rmtree(here, ignore_errors=True)
    os.makedirs(os.path.join(here, "cadr-usb-input", "src"))
    os.makedirs(os.path.join(here, "cadr-terminal", "src"))
    os.makedirs(os.path.join(here, "cadr-common", "src", "cadr"))
    for f in CORE + HEADERS + ["usb_test.c", "cadr-usb-input.c"]:
        shutil.copy(os.path.join(src, f), os.path.join(here, "cadr-usb-input", "src", f))
    for f in TERMINAL + TERMINAL_HEADERS:
        shutil.copy(os.path.join(terminal, f), os.path.join(here, "cadr-terminal", "src", f))
    for f in COMMON:
        shutil.copy(os.path.join(common, f), os.path.join(here, "cadr-common", "src", f))
    for f in COMMON_HEADERS:
        shutil.copy(os.path.join(common, "cadr", f),
                    os.path.join(here, "cadr-common", "src", "cadr", f))
    # A bare name is this package's; the other two are named with their own
    # directory in front, which is also how a reader tells them apart in the
    # list.
    named = record["file"]
    target = (os.path.join(here, named) if "/" in named
              else os.path.join(here, "cadr-usb-input", "src", named))
    if not os.path.exists(target):
        return here, (f"@file {named} is not one of the sources this check builds; "
                      "a record aimed anywhere else could never be caught")
    text = open(target).read()
    hits = text.count(record["old"])
    if hits != 1:
        return here, (f"@old matches {hits} times in {named}; a record names its "
                      "lines exactly once or it has rotted")
    open(target, "w").write(text.replace(record["old"], record["new"]))
    return here, None


def build_and_run(here, cc, cflags):
    src = os.path.join(here, "cadr-usb-input", "src")
    terminal = os.path.join(here, "cadr-terminal", "src")
    common = os.path.join(here, "cadr-common", "src")
    binary = os.path.join(here, "usb_test")
    cmd = ([cc] + cflags.split() + ["-I" + common, "-I" + terminal, "-o", binary,
            os.path.join(src, "usb_test.c")]
           + [os.path.join(src, f) for f in CORE]
           + [os.path.join(terminal, f) for f in TERMINAL]
           + [os.path.join(common, f) for f in COMMON])
    build = subprocess.run(cmd, capture_output=True, text=True)
    if build.returncode != 0:
        return None, build.stderr.strip().splitlines()[:6]
    run = subprocess.run([binary, "--work", here], capture_output=True, text=True, timeout=900)
    return run, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--only")
    ap.add_argument("--cc", default="cc")
    ap.add_argument("--cflags", default="-O2 -Wall -Wextra -std=gnu11")
    args = ap.parse_args()

    src = os.path.dirname(os.path.abspath(args.list))
    common = os.path.abspath(os.path.join(src, "..", "..", "cadr-common", "src"))
    terminal = os.path.abspath(os.path.join(src, "..", "..", "cadr-terminal", "src"))
    os.makedirs(args.work, exist_ok=True)
    records = parse(args.list)
    if args.only:
        records = [r for r in records if r["mutation"] == args.only]
        if not records:
            sys.exit(f"no record named {args.only}")

    print(f"mutations: {len(records)} records, from {os.path.basename(args.list)}")
    caught = survived = broken = 0
    for r in records:
        here, why = apply(r, args.work, src, common, terminal)
        if why:
            print(f"  BROKEN    {r['mutation']}\n              {why}")
            broken += 1
            continue
        run, build_error = build_and_run(here, args.cc, args.cflags)
        if build_error:
            print(f"  BROKEN    {r['mutation']}: it does not compile")
            for line in build_error:
                print(f"              {line}")
            broken += 1
            continue
        if run.returncode != 0:
            # **A RUN THAT FAILED WITH NOTHING TO SAY IS BROKEN AND NOT
            # CAUGHT.**  A mutation was once counted as caught because a
            # syntax error in its own `@new` stopped the build; this
            # is the same trap one step later, and it happened here: a socket
            # path grown past what a Unix socket allows made the check exit
            # before it had asserted anything, and every record with a long
            # name was "caught" by that.  A record is caught by a line that
            # names what was noticed, or it is not caught.
            first = next((l for l in run.stdout.splitlines() + run.stderr.splitlines()
                          if "FAIL:" in l), None)
            if first is None:
                print(f"  BROKEN    {r['mutation']}: it failed with no FAIL line, "
                      "so what caught it is not the check")
                for line in (run.stdout.splitlines()[-3:] + run.stderr.splitlines()[-3:]):
                    print(f"              {line.strip()}")
                broken += 1
                continue
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
