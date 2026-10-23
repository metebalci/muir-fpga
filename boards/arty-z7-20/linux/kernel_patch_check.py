#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# THE ZYNQ BOARDS' KERNEL IS BUILT WITH ITS PATCH, OR THE BUILD FAILS.
#
#     kernel_patch_check.py patches <shared tree> <defconfig>
#     kernel_patch_check.py patched <shared tree> <Buildroot output directory>
#
# The Arty Z7-20 and the Kria KR260 build Buildroot's mainline kernel with one
# patch, board/arty-z7-20/patches/linux/0001-*.patch in the shared external
# tree (this file's), whose header says what it fixes: the GEM's transmit
# queues stalled for good after a link flap.  Both boards' defconfigs name the
# directory as BR2_GLOBAL_PATCH_DIR.  Buildroot applies a directory's
# `*.patch` in name order and says nothing of a directory it finds empty, or
# of a defconfig that names none, so nothing in the build itself would notice
# the patch gone.  This does.
#
# **`patches`, BEFORE THE BUILD** (`make check` and each board's
# `buildroot-*-check`): the defconfig names the directory, and the directory
# holds exactly the files KERNEL_PATCHES names, each adding at least one line.
# A patch renamed, removed, moved into a version directory or joined by
# another fails here.
#
# **`patched`, AFTER THE BUILD** (each board's `buildroot*` targets): the
# kernel's build directory's `.applied_patches_list`, Buildroot's record of
# what support/scripts/apply-patches.sh applied, lists exactly KERNEL_PATCHES,
# and every line each patch adds is in the file it patched, in the built tree.
# A rebuild target that reconfigures the kernel does not patch it again, so a
# patch changed after the first build fails here until the kernel's build
# directory is made anew.
#
# **WHAT IT DOES NOT HOLD** is that the patch fixes anything; the board's flap
# test does (the patch header says what it measured).

import os
import re
import sys

PATCH_DIR = "board/arty-z7-20/patches"
PATCH_DIR_LINE = '"$(BR2_EXTERNAL_CADR_PATH)/' + PATCH_DIR + '"'
# Under PATCH_DIR, in the order Buildroot applies them.
KERNEL_PATCHES = ("linux/0001-net-macb-restart-the-transmit-queues-after-a-link-flap.patch",)


def die(*lines):
    for line in lines:
        print("kernel-patch: " + line, file=sys.stderr)
    sys.exit(1)


def patch_files(patch):
    """A unified diff's files, as {path: [added lines]}, the path with its
    first component (a/, b/) stripped as `patch -p1` does."""
    files, cur = {}, None
    for line in open(patch).read().splitlines():
        if line.startswith("+++ "):
            cur = line[4:].split("\t")[0].split("/", 1)[1]
            files.setdefault(cur, [])
        elif cur and line.startswith("+"):
            files[cur].append(line[1:])
    return files


def patches(tree, defconfig):
    got = None
    for line in open(defconfig).read().splitlines():
        m = re.match(r"^BR2_GLOBAL_PATCH_DIR=(.*)$", line)
        if m:
            got = m.group(1)
    if got != PATCH_DIR_LINE:
        die("%s: BR2_GLOBAL_PATCH_DIR is %s, not %s" % (defconfig, got, PATCH_DIR_LINE))
    root = os.path.join(tree, PATCH_DIR)
    have = sorted(os.path.relpath(os.path.join(d, f), root)
                  for d, _, fs in os.walk(root) for f in fs)
    if have != sorted(KERNEL_PATCHES):
        die("%s holds %s, wanting exactly %s" % (PATCH_DIR, have, list(KERNEL_PATCHES)))
    for rel in KERNEL_PATCHES:
        files = patch_files(os.path.join(root, rel))
        if not files or not all(files.values()):
            die("%s/%s adds no line to %s" % (PATCH_DIR, rel, sorted(files) or "any file"))
    print("kernel-patch: %s carries %s, holding exactly %d kernel patch(es)"
          % (os.path.basename(defconfig), PATCH_DIR, len(KERNEL_PATCHES)))


def patched(tree, out):
    build = os.path.join(out, "build")
    hits = [d for d in os.listdir(build) if re.fullmatch(r"linux-[0-9][0-9.]*", d)]
    if len(hits) != 1:
        die("%d kernel build directories in %s, wanting one" % (len(hits), build))
    linux = os.path.join(build, hits[0])
    listed = os.path.join(linux, ".applied_patches_list")
    if not os.path.isfile(listed):
        die("no %s: Buildroot applied no patch to the kernel" % listed)
    applied = [os.path.realpath(p) for p in open(listed).read().split()]
    wanted = [os.path.realpath(os.path.join(tree, PATCH_DIR, rel)) for rel in KERNEL_PATCHES]
    if applied != wanted:
        die("%s lists %s, wanting %s" % (listed, applied, wanted))
    n = 0
    for rel in KERNEL_PATCHES:
        for path, added in patch_files(os.path.join(tree, PATCH_DIR, rel)).items():
            built = open(os.path.join(linux, path)).read().splitlines()
            missing = [a for a in added if a not in built]
            if missing:
                die("%s in the built kernel lacks %d line(s) %s adds, the first %r"
                    % (path, len(missing), rel, missing[0]))
            n += len(added)
    print("kernel-patch: the kernel was built with its %d patch(es) applied, all %d added"
          " line(s) in the built tree" % (len(KERNEL_PATCHES), n))


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "patches":
        patches(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "patched":
        patched(sys.argv[2], sys.argv[3])
    else:
        die("usage: kernel_patch_check.py patches <tree> <defconfig> | patched <tree> <output>")


if __name__ == "__main__":
    main()
