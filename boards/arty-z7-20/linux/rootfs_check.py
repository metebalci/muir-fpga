#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# THE IMAGE IS THE TARGET TREE IT WAS MADE FROM, OR THE BUILD FAILS.
#
# **Why this exists.**  `make buildroot-cora` once wrote a root filesystem
# image that was OLDER than the packages in its own target directory, exited 0
# and said nothing: the image was written at 16:46, `cadr-console` was built at
# 16:47 and installed into `output/target` at 16:48, and the image was never
# made again.  The image that was then staged and served carried a
# `cadr-console` with no `debug-cable` words in it and three init scripts from
# an earlier commit, while the target tree beside it held the right files.  The
# board ran the old programs on the new fabric, and nothing anywhere said so.
#
# Nothing in any flow asked the one question that would have caught it: does
# the image hold what the target tree holds?  This asks it, after the image is
# written, on every `buildroot` target of every board.
#
# **It is a different question from `board/arty-z7-20/post-build.sh`'s, at a
# different moment, and both are wanted.**  That script runs during
# `target-finalize`, BEFORE the image, and asks whether the TARGET holds only
# the programs the packages install --- the ghost a renamed package leaves
# behind.  This runs after, and asks whether the IMAGE is that target.  A
# target can be right and the image stale; a target can be wrong and the image
# faithfully carry the ghost.  Neither check sees the other's fault.
#
# **The derivation is from the source tree, and this file will not guess.**
# Buildroot's own `$(O)/build/packages-file-list.txt` reads like a manifest of
# what the packages install and is not one --- post-build.sh's header records
# it naming two packages that had been deleted a day earlier --- so the
# expected set is read from the packages themselves:
#
#   * from `<pkg>/<pkg>.mk`, every `$(TARGET_DIR)/<path>` an install command
#     names: `usr/bin/muir` and the `root/.muirrc` symlink from muir's own
#     rules, `usr/bin/ozd` from ozd's, and `etc/init.d/S8x...` from each
#     INSTALL_INIT_SYSV;
#   * and where that .mk delegates the target install to the program's own
#     `src/Makefile` --- `$(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install`,
#     which is what every package of ours does, with any other `NAME=value`
#     on that line handed on as make would hand it --- the rule of that
#     Makefile for the goal named, which is where `usr/bin/cadr-*` and
#     `usr/share/cadr/*.sh` actually come from.  That rule is read command by
#     command, for what each one writes: an install(1), a sed(1) redirected
#     into one file under $(DESTDIR), a grep -q that only tests, and a chmod
#     of a file already derived.
#
# A command in either file that this cannot classify is a FAILURE here and not
# a quiet omission, because a derivation that comes out short is the shape of
# every silent-omission bug this repository has recorded.  THE DERIVATION HAS
# REFUSED BEFORE, FOR EVERY IMAGE OF EVERY BOARD, AND NOTHING SAID SO: cadr-
# common's install line gained a `CADR_BOARD=` and its rule a sed, and this
# check, which runs only after a whole image build, stopped every build that
# reached it.  So `rootfs_check.py packages <BR2_EXTERNAL>` runs the same
# derivation with no Buildroot at all, in `make check`, and holds it to the
# paths the installed scripts name (see `packages_check`).  A package added
# under `package/` joins the set by existing; a typed list would rot, and the
# one in the Makefile's BR_RECONFIGURE had already rotted once.
#
# **The .config decides which packages count**, so this is one script for both
# boards: the Cora Z7-07S has no USB input and its `.config` says so, and a
# guard demanding `usr/bin/cadr-usb-input` of that image would be wrong about
# the machine that was asked for.
#
# **The image is opened rather than trusted.**  `rootfs.cpio.uboot` is a
# U-Boot legacy image --- a 64-byte header carrying the payload's length and
# its CRC32 --- around a gzip around a newc cpio archive.  All three are read
# here: the header's magic and data CRC say the file is whole, and the cpio is
# parsed entry by entry, so what is compared is the bytes a booting board
# would unpack and not the bytes of some directory beside it.

import gzip
import hashlib
import os
import re
import shlex
import struct
import sys
import zlib

UIMAGE_MAGIC = 0x27051956
UIMAGE_HEADER = 64
CPIO_MAGIC = b"070701"
CPIO_TRAILER = "TRAILER!!!"


def die(what, *rest):
    print("the image and the target: " + what, file=sys.stderr)
    for line in rest:
        print(line, file=sys.stderr)
    sys.exit(1)


# ------------------------------------------------------------- the source tree


def make_vars(text, overrides=None):
    """The `NAME := value` assignments of a Makefile, expanded.

    A name assigned more than once with different values is left unexpanded:
    those are the arms of a conditional, and which arm holds depends on what
    the build was given, which this cannot know.  A destination that names
    one is refused below rather than resolved to whichever arm came last.
    `overrides` are the command line's `NAME=value`, which GNU make lets win
    over every assignment in the file."""
    table, seen = {}, {}
    for name, value in re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)\s*[:?]?=\s*(.*)$",
                                  text, re.M):
        seen.setdefault(name, set()).add(value.strip())
    for name, values in seen.items():
        if len(values) == 1:
            table[name] = values.pop()
    table.update(overrides or {})
    for _ in range(4):                      # a value naming another value
        for name, value in list(table.items()):
            table[name] = re.sub(r"\$\(([A-Za-z_][A-Za-z0-9_]*)\)",
                                 lambda m: table.get(m.group(1), m.group(0)),
                                 value)
    return table


def expand(word, table):
    return re.sub(r"\$\(([A-Za-z_][A-Za-z0-9_]*)\)",
                  lambda m: table.get(m.group(1), m.group(0)), word)


def logical_lines(text):
    """A Makefile's lines with backslash continuations joined."""
    out, held = [], ""
    for line in text.splitlines():
        if line.endswith("\\"):
            held += line[:-1].strip() + " "
            continue
        out.append((held + line.strip()).strip())
        held = ""
    if held:
        out.append(held.strip())
    return out


def shell_words(command):
    """A recipe line's words, quotes removed, shell operators their own words.

    Parentheses are not operators here: `$(DESTDIR)` is one word."""
    lex = shlex.shlex(command, posix=True, punctuation_chars=";&|<>")
    lex.whitespace_split = True
    return list(lex)


def recipe(text, goal):
    """The commands of the rule for `goal`, continuations joined.  None if the
    Makefile has no such rule."""
    lines = text.splitlines()
    for at, line in enumerate(lines):
        if re.match(r"^%s\s*:(?!=)" % re.escape(goal), line):
            break
    else:
        return None
    body = []
    for line in lines[at + 1:]:
        if not line.startswith("\t"):
            break                           # a blank line or the next rule
        body.append(line)
    commands = []
    for line in logical_lines("\n".join(body)):
        if line and not line.startswith("#"):
            commands.append(line)
    return commands


def under_destdir(word, makefile, where, command):
    """A word naming a path under $(DESTDIR), as the path on the target.

    Whatever is left of the word must be a plain path: a variable still
    standing in it is one this check could not resolve, and a path it cannot
    resolve is a path it cannot compare."""
    if not word.startswith("$(DESTDIR)"):
        die("%s: %s writes outside $(DESTDIR):" % (where, makefile),
            "    " + command)
    path = word[len("$(DESTDIR)"):].lstrip("/")
    if "$" in path:
        die("%s: %s names a destination this check cannot resolve:"
            % (where, makefile), "    " + command,
            "",
            "A variable in it has no single value here (it is set in more "
            "than one arm of a",
            "conditional, or not at all), so the file it installs cannot be "
            "named.")
    return path


def refuse(where, makefile, command, goal):
    die("%s: the `%s` rule of %s runs a command this check "
        "cannot read:" % (where, goal, makefile),
        "    " + command,
        "",
        "Every command there must be an install(1), a sed(1) whose output is "
        "redirected to one",
        "file under $(DESTDIR), a grep -q that only tests, or a chmod of a "
        "file already derived,",
        "so that what reaches the target can be derived from the source "
        "tree.  Teach this check",
        "the new shape or keep the rule to those; do not leave the file out "
        "of the check.")


def src_install_paths(makefile, where, goal="install", overrides=None,
                      origins=None):
    """What `make DESTDIR=... <goal>` in a src/Makefile puts on the target.

    Four shapes of command are read, and each is read for what it writes:

      * `install(1)`: a `-d` makes a directory and installs nothing, and
        anything else names a destination under $(DESTDIR);
      * `sed ... SOURCE > $(DESTDIR)/PATH`: a filter whose one output is a
        file on the target, which is PATH (not in place: `-i` is refused);
      * `grep -q ...`: a test, writing nothing;
      * `chmod MODE $(DESTDIR)/PATH`: a mode, on a PATH this rule has
        already put there, so nothing new.

    A command in any other shape, or with any other shell operator in it,
    stops the build rather than being skipped.  `overrides` are the
    variables the .mk hands this make on its command line.  Where `origins`
    is given, each path installed from a file in the source tree is entered
    there with that file."""
    text = open(makefile).read()
    table = make_vars(text, overrides)
    here = os.path.dirname(makefile)
    commands = recipe(text, goal)
    if commands is None:
        die("%s: %s has no `%s:` rule" % (where, makefile, goal))
    paths = {}

    def origin(path, source):
        full = os.path.join(here, source)
        if origins is not None and "$" not in source and os.path.isfile(full):
            origins[path] = full

    for command in commands:
        try:
            words = [expand(w, table) for w in shell_words(command)]
        except ValueError:                  # an unbalanced quote
            refuse(where, makefile, command, goal)
        operators = [w for w in words if re.fullmatch(r"[;&|<>]+", w)]
        if words[0] == "install":
            if operators:
                refuse(where, makefile, command, goal)
            if "-d" in words:
                continue                    # a directory, not a file
            args = [w for w in words[1:] if not w.startswith("-")]
            # `install -m MODE FILE DEST` swallows MODE as an argument
            if args and words[words.index(args[0]) - 1] == "-m":
                args = args[1:]
            if len(args) < 2:
                die("%s: cannot tell source from destination in:" % where,
                    "    " + command)
            sources, dest = args[:-1], args[-1]
            path = under_destdir(dest, makefile, where, command)
            if command.rstrip().endswith("/") or dest.endswith("/"):
                for s in sources:
                    full = os.path.join(path.rstrip("/"), os.path.basename(s))
                    paths[full] = None
                    origin(full, s)
            else:
                if len(sources) != 1:
                    die("%s: several sources and a destination that is not "
                        "a directory:" % where, "    " + command)
                paths[path] = None
                origin(path, sources[0])
            continue
        if words[0] == "sed":
            if operators != [">"] or words.index(">") != len(words) - 2:
                refuse(where, makefile, command, goal)
            if any(w == "-i" or w.startswith("--in-place") or
                   (re.fullmatch(r"-[a-zA-Z]+", w) and "i" in w)
                   for w in words[1:-2]):
                refuse(where, makefile, command, goal)
            args = [w for w in words[1:-2] if not w.startswith("-")]
            if len(args) != 2:              # the script and one input file
                die("%s: cannot tell the script from the input in:" % where,
                    "    " + command)
            path = under_destdir(words[-1], makefile, where, command)
            paths[path] = None
            origin(path, args[1])
            continue
        if words[0] == "grep":
            if operators or not any(re.fullmatch(r"-[a-zA-Z]*q[a-zA-Z]*", w)
                                    for w in words[1:]):
                refuse(where, makefile, command, goal)
            continue                        # a test; it writes nothing
        if words[0] == "chmod":
            if operators or len(words) < 3:
                refuse(where, makefile, command, goal)
            for w in words[2:]:
                path = under_destdir(w, makefile, where, command)
                if path not in paths:
                    die("%s: %s changes the mode of %s, which nothing before "
                        "it in the rule installs:" % (where, makefile, path),
                        "    " + command)
            continue
        refuse(where, makefile, command, goal)
    if not paths:
        die("%s: %s has an install rule that installs nothing on the target"
            % (where, makefile))
    return paths


def delegation(line, name, pkgdir):
    """A .mk line handing the target install to the package's own Makefile,
    read word by word: `$(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) [NAME=value
    ...] <goal>`.  Returns (goal, the command line's variables), or None when
    the line does not run $(MAKE).  Any other word stops the build: a
    variable in any position is read as one, and a second goal or an option
    this does not know would change which files are installed."""
    words = line.split()
    if "$(MAKE)" not in words:
        return None
    at = words.index("$(MAKE)")
    if any(w != "$(TARGET_MAKE_ENV)" for w in words[:at]):
        die("%s: something before $(MAKE) this check cannot read:" % name,
            "    " + line)
    rest = words[at + 1:]
    directory, goals, overrides = None, [], {}
    mk_vars = make_vars(open(os.path.join(pkgdir, name + ".mk")).read())
    i = 0
    while i < len(rest):
        w = rest[i]
        if w == "-C" and i + 1 < len(rest):
            directory = rest[i + 1]
            i += 2
            continue
        m = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(\S*)", w)
        if m:
            overrides[m.group(1)] = expand(m.group(2), mk_vars)
        elif w.startswith("-"):
            die("%s: an option to $(MAKE) this check does not know:" % name,
                "    " + line)
        else:
            goals.append(w)
        i += 1
    if directory != "$(@D)":
        die("%s: $(MAKE) is not run in the package's own build directory:"
            % name, "    " + line)
    if overrides.get("DESTDIR") != "$(TARGET_DIR)":
        die("%s: $(MAKE) is not given DESTDIR=$(TARGET_DIR):" % name,
            "    " + line)
    if len(goals) != 1:
        die("%s: $(MAKE) is run for %d goals, wanting exactly one:"
            % (name, len(goals)), "    " + line)
    del overrides["DESTDIR"]
    return goals[0], overrides


def package_paths(pkgdir, name, origins=None):
    """What one package installs: its .mk's own commands, and the src/Makefile
    install rule where the .mk delegates to it.

    The value of each path is the symlink target where the .mk makes a symlink,
    and None where it is a plain file.  Where `origins` is given, each path
    installed from a file in this tree (an init script, a shell file) is
    entered there with that file."""
    mk = os.path.join(pkgdir, name + ".mk")
    if not os.path.isfile(mk):
        die("%s has no %s.mk" % (pkgdir, name))
    text = open(mk).read()
    paths = {}
    inside = False
    for line in logical_lines(text):
        if re.match(r"^define\s+[A-Z0-9_]+_INSTALL_(TARGET_CMDS|INIT_SYSV)\s*$",
                    line):
            inside = True
            continue
        if inside and line == "endef":
            inside = False
            continue
        if not inside or not line or line.startswith("#"):
            continue
        if "$(TARGET_DIR)" not in line:
            die("%s: an install command naming no $(TARGET_DIR):" % name,
                "    " + line)
        handed = delegation(line, name, pkgdir)
        if handed:
            goal, overrides = handed
            src = os.path.join(pkgdir, "src", "Makefile")
            if not os.path.isfile(src):
                die("%s hands its target install to %s and there is no such "
                    "file" % (name, src))
            paths.update(src_install_paths(src, name, goal, overrides,
                                           origins))
            continue
        words = line.split()
        if words[0] == "ln" and "-sf" in words:
            args = [w for w in words[1:] if not w.startswith("-")]
            if len(args) != 2:
                die("%s: cannot read the symlink:" % name, "    " + line)
            link, dest = args
            paths[dest.replace("$(TARGET_DIR)/", "")] = link
            continue
        if words[0] in ("$(INSTALL)", "install"):
            if "-d" in words:
                continue                    # a directory, not a file
            dest = words[-1]
            if not dest.startswith("$(TARGET_DIR)/"):
                die("%s: an install whose destination is not under "
                    "$(TARGET_DIR):" % name, "    " + line)
            paths[dest[len("$(TARGET_DIR)/"):]] = None
            m = re.fullmatch(r"\$\([A-Z0-9_]+_PKGDIR\)/(\S+)", words[-2])
            if origins is not None and m and \
                    os.path.isfile(os.path.join(pkgdir, m.group(1))):
                origins[dest[len("$(TARGET_DIR)/"):]] = \
                    os.path.join(pkgdir, m.group(1))
            continue
        die("%s: an install command this check cannot read:" % name,
            "    " + line,
            "",
            "The set of files the image must carry is derived from these "
            "commands.  A command it",
            "cannot classify would silently drop a file from the check, so it "
            "stops the build instead.")
    return paths


def expected_files(external, config, origins=None):
    """Every path our enabled packages put on the target.

    `external` is a BR2_EXTERNAL as Buildroot takes it, so it may name more
    than one tree: the Cora Z7-07S's image is built from both, its own holding
    only the board and every package being the other's.  A `config` of None
    counts every package, which is what `packages` below asks."""
    roots = [os.path.join(tree, "package") for tree in external.split(":")]
    if not any(os.path.isdir(r) for r in roots):
        die("no package directory in any of " + external)
    symbols = None if config is None else \
        set(re.findall(r"^(BR2_PACKAGE_[A-Z0-9_]+)=y$",
                       open(config).read(), re.M))
    expected, packages = {}, 0
    for pkgdir in sorted(os.path.join(r, n) for r in roots
                         if os.path.isdir(r) for n in os.listdir(r)):
        name = os.path.basename(pkgdir)
        if not os.path.isdir(pkgdir):
            continue
        cfg = os.path.join(pkgdir, "Config.in")
        if not os.path.isfile(cfg):
            die("%s has no Config.in" % name)
        sym = re.search(r"^config\s+(BR2_PACKAGE_[A-Z0-9_]+)\s*$",
                        open(cfg).read(), re.M)
        if not sym:
            die("%s/Config.in declares no BR2_PACKAGE_ symbol" % name)
        if symbols is not None and sym.group(1) not in symbols:
            continue                        # not in this board's image
        packages += 1
        for path, link in package_paths(pkgdir, name, origins).items():
            expected[path] = link
    if not packages:
        die("no package under %s is enabled in %s;"
            % (external, config or "any configuration"),
            "the check would be vacuous, which is no check at all.")
    return expected, packages


# ------------------------------------------------------------------- the image


def uboot_payload(path):
    """The gzip'd cpio inside a U-Boot legacy image, its header read rather
    than skipped, so a truncated file is caught here."""
    blob = open(path, "rb").read()
    if len(blob) <= UIMAGE_HEADER:
        die("%s is %d bytes, which is not an image" % (path, len(blob)))
    magic, _hcrc, _time, size, _load, _ep, dcrc, _os, _arch, _type, comp = \
        struct.unpack(">IIIIIIIBBBB", blob[:32])
    if magic != UIMAGE_MAGIC:
        die("%s does not start with U-Boot's magic (0x%08x, wanting 0x%08x)"
            % (path, magic, UIMAGE_MAGIC))
    payload = blob[UIMAGE_HEADER:]
    if size != len(payload):
        die("%s says its payload is %d bytes and carries %d"
            % (path, size, len(payload)))
    if zlib.crc32(payload) & 0xFFFFFFFF != dcrc:
        die("%s: the payload does not match the CRC in its own header; the "
            "file is damaged" % path)
    # THE HEADER'S COMPRESSION BYTE IS NOT THE ANSWER AND SAYING SO COSTS
    # NOTHING.  Measured on this image: it reads 0, "no compression", over a
    # payload whose first two bytes are gzip's own magic.  Buildroot wraps the
    # already-compressed `rootfs.cpio.gz` and leaves the field alone, because
    # for a type-3 ramdisk it is the kernel that unpacks the initramfs and the
    # loader never looks.  So the payload is sniffed rather than trusted, and
    # a payload that is neither is a failure rather than a guess.
    if payload[:2] == b"\x1f\x8b":
        return gzip.decompress(payload)
    if payload[:6] == CPIO_MAGIC:
        return payload
    die("%s carries neither a gzip nor a cpio (its header says compression "
        "%d)" % (path, comp))


def cpio_entries(blob):
    """Every entry of a newc cpio archive: path -> (mode, bytes)."""
    entries, at = {}, 0
    while at + 110 <= len(blob):
        if blob[at:at + 6] != CPIO_MAGIC:
            die("the cpio inside the image is not in the newc format at "
                "offset %d" % at)
        fields = [int(blob[at + 6 + 8 * i: at + 14 + 8 * i], 16)
                  for i in range(13)]
        mode, filesize, namesize = fields[1], fields[6], fields[11]
        name_at = at + 110
        name = blob[name_at:name_at + namesize - 1].decode()
        data_at = (name_at + namesize + 3) & ~3
        if name == CPIO_TRAILER:
            break
        entries[name.lstrip("./") or "."] = (mode, blob[data_at:data_at + filesize])
        at = (data_at + filesize + 3) & ~3
    if not entries:
        die("the cpio inside the image holds no entries")
    return entries


# -------------------------------------------------------------------- the check


def ours(path):
    """A path on the target that only our packages would put there."""
    base = os.path.basename(path)
    return (path.startswith("usr/share/cadr/") or "cadr" in base
            or base in ("muir", "ozd"))


# A path an installed script names, as `PROG=/usr/bin/cadr-serial` or
# `FPGARC_SH=/usr/share/cadr/fpgarc.sh` do.  It starts at a word boundary so
# that `$WORK/usr/bin/x` in a test is not read as one.
NAMED_PATH = re.compile(r"(?<![\w./$-])/((?:usr|etc)/[\w./+-]*[\w+-])")


def packages_check(external):
    """The derivation alone, over every package, with no Buildroot at all.

    `make check` runs this, because the image check runs only after a whole
    Buildroot build, and a refusal there is found by whoever next builds an
    image --- the derivation refused two shapes of cadr-common's for every
    image of every board, and no build that ran in between said so where
    anyone looked.  A refusal here is the same refusal, at the commit.

    And one thing a derivation cannot ask of itself: whether it is RIGHT.  A
    renamed destination derives cleanly to the wrong name.  The witness here
    is the scripts the packages install, which name the files they run by
    their paths on the target: every such path of ours that an installed
    script names must be one the derivation says some package installs.
    That is a second, independent statement of the same set, written by
    whoever wrote the script, and the two have to agree."""
    origins = {}
    expected, count = expected_files(external, None, origins)
    named, scripts = {}, 0
    for path, source in sorted(origins.items()):
        with open(source, "rb") as f:
            head = f.read(2)
        if head != b"#!" and not source.endswith(".sh"):
            continue                        # not a script
        scripts += 1
        for number, line in enumerate(open(source), 1):
            if line.lstrip().startswith("#"):
                continue                    # a comment names nothing it runs
            for m in NAMED_PATH.finditer(line):
                if ours(m.group(1)):
                    named.setdefault(m.group(1), []).append(
                        "%s:%d" % (source, number))
    if not scripts or not named:
        die("no installed script names a path of ours; the cross-check would "
            "be vacuous, which is no check at all.")
    missing = sorted(p for p in named if p not in expected)
    if missing:
        print("the packages: A SCRIPT ON THE TARGET NAMES A FILE NO PACKAGE "
              "INSTALLS.", file=sys.stderr)
        print(file=sys.stderr)
        for p in missing:
            print("    /%-32s named at %s" % (p, ", ".join(named[p])),
                  file=sys.stderr)
        print(file=sys.stderr)
        print("Either the install rule puts it somewhere else, or the script "
              "names a file that is", file=sys.stderr)
        print("not there.  The derivation says the packages install:",
              file=sys.stderr)
        for p in sorted(expected):
            print("    /" + p, file=sys.stderr)
        sys.exit(1)
    for p in sorted(expected):
        print("    /" + p)
    print("the packages: %d file(s) of %d package(s) derived; the %d path(s) "
          "of ours that %d installed script(s) name are all among them"
          % (len(expected), count, len(named), scripts))


def target_bytes(target, path):
    full = os.path.join(target, path)
    if os.path.islink(full):
        return None, os.readlink(full).encode()
    if not os.path.isfile(full):
        return "missing", None
    return None, open(full, "rb").read()


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "packages":
        for path in sys.argv[2].split(":"):
            if not os.path.isdir(path):
                die("no such directory: " + path)
        packages_check(sys.argv[2])
        return
    if len(sys.argv) != 4:
        die("usage: rootfs_check.py <BR2_EXTERNAL> <output directory> "
            "<image>",
            "       rootfs_check.py packages <BR2_EXTERNAL>")
    external, out, image = sys.argv[1:]
    config = os.path.join(out, ".config")
    target = os.path.join(out, "target")
    for path in external.split(":") + [out, target]:
        if not os.path.isdir(path):
            die("no such directory: " + path)
    for path in (config, image):
        if not os.path.isfile(path):
            die("no such file: " + path)

    expected, packages = expected_files(external, config)
    entries = cpio_entries(uboot_payload(image))

    stale, differ, absent = [], [], []
    for path in sorted(expected):
        want_link = expected[path]
        problem, want = target_bytes(target, path)
        if problem:
            absent.append((path, "the package installs it and the target "
                                 "tree has no such file"))
            continue
        if want_link is not None and want.decode() != want_link:
            absent.append((path, "the target's symlink points at %s and the "
                                 "package makes it point at %s"
                                 % (want.decode(), want_link)))
            continue
        if path not in entries:
            absent.append((path, "in the target tree, NOT IN THE IMAGE"))
            continue
        got = entries[path][1]
        if got != want:
            differ.append((path,
                           hashlib.sha256(want).hexdigest()[:16],
                           hashlib.sha256(got).hexdigest()[:16],
                           len(want), len(got)))

    # And nothing of ours that no package installs: the image can carry a ghost
    # the target tree no longer has, which is what a stale image IS.
    # A directory of ours is not a ghost: `usr/share/cadr` is made by an
    # install, holds what the package puts in it, and its name would match.
    for path in sorted(entries):
        base = os.path.basename(path)
        kind = entries[path][0] & 0o170000
        if kind not in (0o100000, 0o120000):
            continue
        if ours(path) and path not in expected:
            stale.append(path)

    if absent or differ or stale:
        print("the image and the target: THE IMAGE IS NOT THE TARGET TREE IT "
              "WAS MADE FROM.", file=sys.stderr)
        print(file=sys.stderr)
        print("    image  %s" % image, file=sys.stderr)
        print("    target %s" % target, file=sys.stderr)
        print(file=sys.stderr)
        for path, why in absent:
            print("    %-34s %s" % (path, why), file=sys.stderr)
        for path, want, got, nwant, ngot in differ:
            print("    %-34s the target's %s (%d bytes), the image's %s (%d "
                  "bytes)" % (path, want, nwant, got, ngot), file=sys.stderr)
        for path in stale:
            print("    %-34s in the image and installed by no package"
                  % path, file=sys.stderr)
        print(file=sys.stderr)
        print("The image was written before these files reached the target, "
              "or from another target", file=sys.stderr)
        print("tree altogether.  It is not a file to edit: build it again, "
              "with the rebuild target for", file=sys.stderr)
        print("this board, so that every package is forced and the image is "
              "written last.", file=sys.stderr)
        sys.exit(1)

    print("the image and the target: %d file(s) of %d package(s) "
          "byte-identical in %s"
          % (len(expected), packages, os.path.basename(image)))


if __name__ == "__main__":
    main()
