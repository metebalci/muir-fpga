#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# THE DE25-Nano's IMAGE IS BUILT FROM WHAT ITS FILES SAY, OR THE BUILD FAILS.
#
#     buildroot_check.py pins     <external tree>
#     buildroot_check.py configs  <external tree> <Buildroot output directory>
#     buildroot_check.py programs <external tree> <directory of programs>
#
# Two questions Buildroot does not ask, each of which it answers silently in
# the wrong direction.
#
# **`pins`, BEFORE THE BUILD: every pinned source has a hash.**  The three
# sources Buildroot does not carry --- Altera's TF-A, U-Boot and kernel --- are
# pinned to commits in the defconfig and fetched from git.  BR2_DOWNLOAD_FORCE_
# CHECK_HASHES makes a download fail when its hash file has no line for it,
# but a download with NO hash file at all passes with a warning
# (support/download/check-hash: "WARNING: no hash file", exit 0).  So a pin
# moved in the defconfig without a hash beside it would build whatever the
# network handed over.  This asserts, for each of the three, that
# board/de25-nano/patches/<package>/<commit>/<package>.hash exists and has a
# sha256 line for the tarball Buildroot makes of exactly that commit
# (`<package>-<commit>-git4.tar.gz`, BR_FMT_VERSION_git in
# package/pkg-download.mk).  It is pure Python over three files and needs no
# Buildroot, so `make check` runs it too.
#
# **`configs`, AFTER THE BUILD: every line we wrote holds.**  Kconfig drops a
# line whose dependencies are not met, or whose symbol does not exist, without
# a word, and the file that asked for it goes on reading as if it held.  Three
# files here are lists of such lines --- the Buildroot defconfig, the kernel's
# fragment and U-Boot's --- and each is held against the .config it was
# applied to.  The one this would have caught first is the board's own
# address map: `BR2_CADR_BOARD_DE25_NANO=y` dropped would build every program
# for a Zynq board and nothing would say so.  So it also opens what cadr-common
# staged and what the image's programs say about themselves, and asks both for
# this board's map.
#
# **`programs`: the same question of programs built anywhere.**  `make check`
# compiles every program on the build host with the DE25-Nano's map and hands
# the directory here, so that a map that does not compile, or a program that
# does not say this board's addresses, fails the gate and not a board.

import os
import re
import sys

PINNED = (
    # (Buildroot package, the defconfig symbol holding its commit)
    ("arm-trusted-firmware", "BR2_TARGET_ARM_TRUSTED_FIRMWARE_CUSTOM_REPO_VERSION"),
    ("uboot", "BR2_TARGET_UBOOT_CUSTOM_REPO_VERSION"),
    ("linux", "BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION"),
)
GIT_SUFFIX = "-git4"
DEFCONFIG = "configs/de25_nano_defconfig"
PATCHES = "board/de25-nano/patches"
FRAGMENTS = (
    # (the fragment, the package whose .config it is merged into)
    ("board/de25-nano/linux/linux.fragment", "linux"),
    ("board/de25-nano/uboot/uboot.fragment", "uboot"),
)


def die(*lines):
    for line in lines:
        print("buildroot-de25: " + line, file=sys.stderr)
    sys.exit(1)


def settings(path):
    """A defconfig or fragment's settings, as {SYMBOL: value}, where a
    `# X is not set` line is the value None."""
    out = {}
    for line in open(path).read().splitlines():
        m = re.match(r"^((?:BR2|CONFIG)_[A-Za-z0-9_]+)=(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2)
            continue
        m = re.match(r"^# ((?:BR2|CONFIG)_[A-Za-z0-9_]+) is not set$", line)
        if m:
            out[m.group(1)] = None
    return out


def pins(tree):
    defconfig = settings(os.path.join(tree, DEFCONFIG))
    for pkg, sym in PINNED:
        value = defconfig.get(sym)
        if not value:
            die("%s names no %s: the pin this check holds is gone" % (DEFCONFIG, sym))
        commit = value.strip('"')
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            die("%s=%s is not a 40-digit commit: a branch or a tag moves, and a "
                "pin must not" % (sym, value))
        hashfile = os.path.join(tree, PATCHES, pkg, commit, pkg + ".hash")
        if not os.path.isfile(hashfile):
            die("%s is pinned to %s and there is no %s" % (pkg, commit, hashfile),
                "Buildroot would fetch it with a warning and check nothing.  Fetch it",
                "once, digest the tarball Buildroot made, and write the hash file.")
        tarball = "%s-%s%s.tar.gz" % (pkg, commit, GIT_SUFFIX)
        found = [l for l in open(hashfile).read().splitlines()
                 if re.fullmatch(r"sha256\s+[0-9a-f]{64}\s+" + re.escape(tarball), l.strip())]
        if len(found) != 1:
            die("%s has %d sha256 line(s) for %s, wanting exactly one"
                % (hashfile, len(found), tarball))
        print("buildroot-de25: %-22s pinned to %s, sha256 %s"
              % (pkg, commit[:12], found[0].split()[1][:16]))


def build_dir(out, pkg):
    """output/build/<pkg>-<version>, the one the output directory has."""
    build = os.path.join(out, "build")
    hits = [d for d in os.listdir(build)
            if re.fullmatch(re.escape(pkg) + r"-[0-9a-f]{40}", d)]
    if len(hits) != 1:
        die("%d build directories for %s in %s, wanting one" % (len(hits), pkg, build))
    return os.path.join(build, hits[0])


def hold(what, wanted, got_path):
    got = settings(got_path)
    wrong = []
    for sym, want in sorted(wanted.items()):
        have = got.get(sym)
        if want is None:
            if have not in (None, "n"):
                wrong.append("%s: wanted not set, the build has %s=%s" % (sym, sym, have))
        elif have != want:
            wrong.append("%s: wanted %s, the build has %s"
                         % (sym, want, "it not set" if have is None else have))
    if wrong:
        die("%s: %d line(s) do not hold in %s:" % (what, len(wrong), got_path),
            *["    " + w for w in wrong])
    print("buildroot-de25: %s: all %d line(s) hold in the built .config" % (what, len(wanted)))


def board_map(header):
    """The DE25-Nano's half of cadr_board.h, as {NAME: value}."""
    text = open(header).read()
    m = re.search(r"#if defined\(CADR_BOARD_DE25_NANO\)\n(.*?)\n#else", text, re.S)
    if not m:
        die("%s has no CADR_BOARD_DE25_NANO half" % header)
    out = {}
    for name, value in re.findall(r"^#define (CADR_BOARD_[A-Z0-9_]+)\s+(\S.*)$", m.group(1), re.M):
        out[name] = value.strip().strip('"')
    return out


def configs(tree, out):
    hold(DEFCONFIG, settings(os.path.join(tree, DEFCONFIG)), os.path.join(out, ".config"))
    for frag, pkg in FRAGMENTS:
        hold(frag, settings(os.path.join(tree, frag)),
             os.path.join(build_dir(out, pkg), ".config"))

    # The board's map reached the programs.  cadr-common stages the header
    # with the board's define on its first line, and the programs in the
    # image print this board's addresses and ports in their own words.
    staged = os.path.join(out, "staging", "usr", "include", "cadr", "cadr_board.h")
    if not os.path.isfile(staged):
        die("no %s: cadr-common staged no board map" % staged)
    first = open(staged).readline().strip()
    if first != "#define CADR_BOARD_DE25_NANO 1":
        die("the staged board map begins %r, not the DE25-Nano's define" % first)
    programs(tree, os.path.join(out, "target", "usr", "bin"))


def programs(tree, bindir):
    """The programs in `bindir` say the DE25-Nano's addresses and ports, in
    their own --help and messages, which are compiled from the one map."""
    header = os.path.join(tree, "..", "..", "..", "arty-z7-20", "linux", "buildroot",
                          "package", "cadr-common", "src", "cadr", "cadr_board.h")
    want = board_map(header)
    said = {
        "cadr-console": ["(default 0x%s, the bottom of %s)"
                         % (want["CADR_BOARD_CONSOLE_HEX"], want["CADR_BOARD_CONSOLE_PORT"]),
                         want["CADR_BOARD_TALLY"] + " reads"],
        "cadr-terminal": ["(default 0x%s)" % want["CADR_BOARD_DISPLAY_HEX"],
                          "(default 0x%s)" % want["CADR_BOARD_COLOR_HEX"],
                          "(default 0x%s)" % want["CADR_BOARD_INPUT_HEX"]],
        "cadr-disk-packs": ["over %s from" % want["CADR_BOARD_PACK_PORT"],
                            "(default 0x%s)" % want["CADR_BOARD_PACK_HEX"]],
        "cadr-serial": ["(default 0x%s)" % want["CADR_BOARD_SERIAL_HEX"]],
        "cadr-readout": ["no %s behind the machine" % want["CADR_BOARD_MEMORY_PORT"]],
        "cadr-checkpoint": [want["CADR_BOARD_TALLY"] + " reads"],
        "cadr-chaosnet": ["skip %s guard" % want["CADR_BOARD_TALLY"]],
        "cadr-usb-input": [],
    }
    for prog, texts in sorted(said.items()):
        path = os.path.join(bindir, prog)
        if not os.path.isfile(path):
            die("no %s in %s" % (prog, bindir))
        blob = open(path, "rb").read()
        for t in texts:
            if t.encode() not in blob:
                die("%s does not say %r: it was not built with this board's map"
                    % (path, t))
    print("buildroot-de25: all %d programs in %s carry the DE25-Nano's map "
          "(the console at 0x%s on %s, the display at 0x%s, %s)"
          % (len(said), bindir, want["CADR_BOARD_CONSOLE_HEX"],
             want["CADR_BOARD_CONSOLE_PORT"], want["CADR_BOARD_DISPLAY_HEX"],
             want["CADR_BOARD_TALLY"]))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "pins":
        pins(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "configs":
        configs(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "programs":
        programs(sys.argv[2], sys.argv[3])
    else:
        die("usage: buildroot_check.py pins <tree> | configs <tree> <output> "
            "| programs <tree> <directory>")


if __name__ == "__main__":
    main()
