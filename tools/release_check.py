#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The release's zips, read back: which there are, what each carries, what it says.

    python3 tools/release_check.py <dir> --commit <sha> [--root .] [--dtc dtc]
                                   [--cadr-system 1003] [--quux-system 2001]
                                   [--fault-commit <sha>]
                                   [--cadr-assets DIR] [--quux-assets DIR]

`make release` runs it over what it built, and `make release-check` over any
directory of zips.  It reads only the zips and this tree's sources, with no
board, no Vivado and no Quartus, and holds:

  1. THE LIST.  Exactly seven zips: the CADR for the Arty Z7-20, the Cora
     Z7-07S, the DE25-Nano and the Kria KR260, and QUUX revision 13 for the
     Arty Z7-20, the DE25-Nano and the Kria KR260.  A missing one, a second
     copy of one, or any other zip under <dir> fails.

  2. EACH BITSTREAM'S IDENTITY, READ OUT OF THE FILE IN THE ZIP.  A Zynq
     `.bit` names its build in its own header (`;UserID=` in the design-name
     field, `tools/build_stamp.tcl`), with the board's top and its part; the
     DE25-Nano's `.core.rbf` carries the same 32-bit USERCODE little-endian at
     two fixed offsets, measured on four core images of two commits and three
     designs (the CADR, QUUX and the fault bitstream), both copies equal.  The
     machine's must be the release commit with a clean tree (nibble 0), the
     fault bitstream's the same commit with the fault nibble (4).  **WHICH
     MACHINE A BITSTREAM IS CANNOT BE READ FROM THE FILE**: its MACHINE-ID is
     in the fabric, and only a running board answers `cadr-console machine`.
     What this holds instead is what the file and the card can say: the
     board's CADR and QUUX bitstreams differ, the fault bitstream is not the
     machine's, every zip of one board carries the same fault bitstream, and
     the card pairs the bitstream with its machine's device tree and loader.

  3. THE MACHINE'S DEVICE TREE AND LOADER.  The kernel's tree, compiled back
     with `dtc`, reserves exactly the machine's region (the node of
     `cadr-reserved.dtsi` or `quux13-reserved.dtsi` for that board, no-map)
     and not the other machine's; a loader that carries U-Boot's own tree
     (`u-boot.img`, `u-boot.itb`) names the same node.

  4. fpgarc.  Its live lines, all of them and in order, for the machine and
     the board: the Kria KR260's CADR card adds `--color-tv` and
     `--display-output both`; `sys/` is served read-write; QUUX's card says
     `--machine quux`.  Its main memory is QUUX's in MW, with the board's own
     most, or the CADR's in boards; the display is the board's own mode.

  5. README.TXT.  The machine, the board, the commit, the System the card is
     for with its muir-sys release and file names, and that the system boots
     with an empty `sys/` (Systems 1003 and 2001 use the band's own error
     table) rather than the older "stops and asks for a file".

  6. With `--cadr-assets` or `--quux-assets`, a directory holding the
     system's two files (its disk or pack, gzipped, and its sources' tarball):
     that what the README tells the user to do with them works on those very
     files --- the tarball holds one folder with `sys/` and `site/` in it, a
     QUUX disk uncompresses to a VHD and a CADR pack to a T-300's or T-80's
     size.  Before release-1003 and release-2001 exist this runs on the
     hand-over's files.

It prints one line a zip and fails with every problem listed.
"""

import argparse
import gzip
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile

# The release, one zip a machine and board.
ZIPS = [("cadr", "arty-z7-20"), ("cadr", "cora-z7-07s"), ("cadr", "de25-nano"),
        ("cadr", "kria-kr260"), ("quux", "arty-z7-20"), ("quux", "de25-nano"),
        ("quux", "kria-kr260")]

# What each board's card is.  `top` and `part` are the Zynq header's design
# name and part; `dtsi` the folder of the board family's reservations;
# `mode` the display mode, fixed per board (docs/display-output.md), and
# `output` the connector it drives (the Cora Z7-07S has none, and its card's
# menu still offers the section); `mw` the most main memory revision 13 has
# on the board (cadr_board.h, CADR_BOARD_QUUX13_MAIN_WORDS_MAX).
BOARDS = {
    "arty-z7-20": dict(fabric="cadr.bit", fault="fault.bit", dtb="zynq-arty-z7-20.dtb",
                       loader="u-boot.img", top="cadr_arty", part="7z020clg400",
                       dtsi="boards/arty-z7-20/linux", mode=(1280, 1024), mw=32,
                       output="HDMI"),
    "cora-z7-07s": dict(fabric="cadr.bit", fault="fault.bit", dtb="zynq-cora-z7-07s.dtb",
                        loader="u-boot.img", top="cadr_cora", part="7z007sclg400",
                        dtsi="boards/arty-z7-20/linux", mode=(1280, 1024), mw=32,
                        output=None),
    "de25-nano": dict(fabric="cadr.core.rbf", fault="fault.core.rbf",
                      dtb="socfpga_agilex5_de25_nano_cadr.dtb", loader="u-boot.itb",
                      top=None, part=None, dtsi="boards/de25-nano/linux",
                      mode=(1280, 1024), mw=64, output="HDMI"),
    "kria-kr260": dict(fabric="cadr.bit", fault="fault.bit",
                       dtb="zynqmp-smk-k26-revA-sck-kr-g-revB-cadr.dtb", loader=None,
                       top="cadr_kr260", part="xck26-sfvc784-2LV-c",
                       dtsi="boards/kria-kr260/linux", mode=(1920, 1080), mw=32,
                       output="DisplayPort"),
}

# Where a DE25-Nano core image carries its USERCODE, little-endian: measured
# on cadr_de25.core.rbf and quux_de25.core.rbf at 6a4e960, and on the fault
# and revision 12 core images at 622c21a, Quartus Prime Pro 26.1.1.
RBF_USERCODE_AT = (434320, 827536)

# Every card's live lines, then each machine's and board's after them, in the
# order mksd-buildroot.sh writes the menu.
LIVE_COMMON = ["--chaos-address 177201", "--chaos-udp 127.0.0.1:42042",
               "--ozd-root sys=/mnt/card/sys", "--ozd-root site=/mnt/card/site",
               "--terminal 0.0.0.0:5900", "--keyboard-boot ctrl,meta"]

problems = []


def bad(zipname, text):
    problems.append("%s: %s" % (zipname, text))


def stamp_of_bit(data):
    """(design, part, userid) from a .bit's header fields a and b."""
    if len(data) < 64 or data[:13] != bytes.fromhex("0009 0ff0 0ff0 0ff0 0ff0 0000 01".replace(" ", "")):
        return None
    pos, fields = 13, {}
    while pos + 3 <= len(data) and len(fields) < 4:
        key = chr(data[pos])
        if key not in "abcd":
            break
        n = struct.unpack(">H", data[pos + 1:pos + 3])[0]
        fields[key] = data[pos + 3:pos + 3 + n].rstrip(b"\0").decode("ascii", "replace")
        pos += 3 + n
    a = fields.get("a", "")
    m = re.search(r";UserID=([0-9A-Fa-f]{8})(;|$)", a)
    return (a.split(";")[0], fields.get("b"), m.group(1).lower() if m else None)


def stamp_of_rbf(data):
    vals = set()
    for off in RBF_USERCODE_AT:
        if len(data) < off + 4:
            return None
        vals.add("%08x" % struct.unpack("<I", data[off:off + 4])[0])
    return vals.pop() if len(vals) == 1 else None


def identity(zipname, board, data, what, fault=False):
    """The stamp a bitstream names, after its header's board checks: the
    machine's top is the board's, the fault bitstream's is `<top>_fault`."""
    b = BOARDS[board]
    if b["top"] is None:
        s = stamp_of_rbf(data)
        if s is None:
            bad(zipname, "%s carries no USERCODE at %s, or two different ones"
                % (what, " and ".join(map(str, RBF_USERCODE_AT))))
        return s
    h = stamp_of_bit(data)
    if h is None:
        bad(zipname, "%s is not a Xilinx .bit with a header" % what)
        return None
    design, part, userid = h
    top = b["top"] + ("_fault" if fault else "")
    if design != top:
        bad(zipname, "%s was built from the top %s, not %s" % (what, design, top))
    if part != b["part"]:
        bad(zipname, "%s is for the part %s, not %s" % (what, part, b["part"]))
    if userid is None:
        bad(zipname, "%s names no UserID in its header" % what)
    return userid


def reserved_node(root, board, machine):
    path = os.path.join(root, BOARDS[board]["dtsi"],
                        "quux13-reserved.dtsi" if machine == "quux" else "cadr-reserved.dtsi")
    text = re.sub(r"/\*.*?\*/", "", open(path).read(), flags=re.S)
    want = "quux13" if machine == "quux" else "cadr"
    nodes = re.findall(r"^\s*(%s@[0-9a-fA-F]+)\s*\{" % want, text, re.M)
    if len(nodes) != 1:
        sys.exit("release_check: %s names %d %s nodes, wanting one" % (path, len(nodes), want))
    return nodes[0]


def check_tree(zipname, dtc, blob_path, node, other):
    out = subprocess.run([dtc, "-q", "-I", "dtb", "-O", "dts", blob_path],
                         capture_output=True, text=True)
    if out.returncode != 0:
        bad(zipname, "dtc cannot read %s" % os.path.basename(blob_path))
        return
    body = out.stdout
    if not re.search(r"\breserved-memory \{", body):
        bad(zipname, "the kernel's tree has no reserved-memory node")
    if len(re.findall(r"\b%s \{[^}]*no-map;" % re.escape(node), body, re.S)) != 1:
        bad(zipname, "the kernel's tree reserves no %s, no-map" % node)
    if re.search(r"\b%s@[0-9a-f]+ \{" % other, body):
        bad(zipname, "the kernel's tree keeps a %s@ node: it is the other machine's" % other)


def live(text):
    return [l.strip() for l in text.replace("\r", "").split("\n")
            if l.strip() and not l.strip().startswith("#")]


def check_fpgarc(zipname, machine, board, text):
    b = BOARDS[board]
    want = list(LIVE_COMMON)
    if machine == "cadr" and board == "kria-kr260":
        want += ["--color-tv", "--display-output both"]
    if machine == "quux":
        want += ["--machine quux"]
    got = live(text)
    if got != want:
        bad(zipname, "fpgarc's live lines are %s, wanting %s" % (got, want))
    flat = re.sub(r"\s+", " ", text.replace("\r", "").replace("\n# ", " "))
    w, h = b["mode"]
    if "%dx%d" % (w, h) not in flat and "%d by %d" % (w, h) not in flat:
        bad(zipname, "fpgarc does not say the board's display mode, %dx%d" % (w, h))
    for ow, oh in {bb["mode"] for bb in BOARDS.values()} - {b["mode"]}:
        if "%dx%d" % (ow, oh) in flat or "%d by %d" % (ow, oh) in flat:
            bad(zipname, "fpgarc names %dx%d, another board's display mode" % (ow, oh))
    if b["output"] and b["output"] not in flat:
        bad(zipname, "fpgarc does not name the board's display output, %s" % b["output"])
    lines = text.replace("\r", "").split("\n")
    if machine == "quux":
        if "#--main-memory-size 32MW" not in lines:
            bad(zipname, "fpgarc has no '#--main-memory-size 32MW' line")
        if "1MW to %dMW on this board" % b["mw"] not in flat:
            bad(zipname, "fpgarc does not give this board's most main memory, %dMW" % b["mw"])
        if any("--main-memory-boards" in l for l in lines):
            bad(zipname, "fpgarc names --main-memory-boards, the CADR's")
    else:
        if "#--main-memory-boards 32" not in lines:
            bad(zipname, "fpgarc has no '#--main-memory-boards 32' line")
        if any("--main-memory-size" in l for l in lines):
            bad(zipname, "fpgarc names --main-memory-size, QUUX's")


def system_files(machine, system):
    """(numbered release, its two files, rolling release, its two files)."""
    if machine == "quux":
        return ("release-%s" % system,
                ["release-%s-disk.vhd.gz" % system, "release-%s-sys.tar.gz" % system],
                "latest-quux", ["quux-disk.vhd.gz", "quux-sys.tar.gz"])
    return ("release-%s" % system,
            ["release-%s-pack.img.gz" % system, "release-%s-sys.tar.gz" % system],
            "latest-cadr", ["cadr-pack.img.gz", "cadr-sys.tar.gz"])


def check_readme(zipname, machine, board, commit, system, text):
    flat = re.sub(r"\s+", " ", text.replace("\r", ""))
    first = text.replace("\r", "").split("\n")[0]
    who = "QUUX" if machine == "quux" else "The CADR"
    if first != "%s on a card --- for the %s and no other board." % (who, board):
        bad(zipname, "README.TXT begins '%s'" % first)
    if "Built from muir-fpga commit %s:" % commit not in flat:
        bad(zipname, "README.TXT does not name commit %s" % commit)
    rel, files, rolling, rolling_files = system_files(machine, system)
    for s in ["System %s" % system, rel, rolling] + files + rolling_files:
        if s not in flat:
            bad(zipname, "README.TXT does not name %s" % s)
    if machine == "quux" and "revision 13" not in flat:
        bad(zipname, "README.TXT does not say QUUX revision 13")
    if "stops and asks for a file" in flat:
        bad(zipname, "README.TXT says the machine stops without sys/; System %s boots "
            "on its own error table" % system)
    if "own error table" not in flat:
        bad(zipname, "README.TXT does not say the system boots on its own error table")


def check_assets(machine, directory, notes):
    """What the README tells the user to do with the system's files, done."""
    if not os.path.isdir(directory):
        problems.append("%s: no such directory of the %s system's files" % (directory, machine))
        return
    names = sorted(os.listdir(directory))
    disk = [n for n in names if n.endswith("disk.vhd.gz" if machine == "quux" else "pack.img.gz")]
    tars = [n for n in names if n.endswith("sys.tar.gz")]
    tag = "%s assets in %s" % (machine, directory)
    if len(disk) != 1 or len(tars) != 1:
        problems.append("%s: wanting one disk or pack and one sys tarball, found %s"
                        % (tag, names))
        return
    with tarfile.open(os.path.join(directory, tars[0])) as t:
        tops = {m.name.split("/")[0] for m in t.getmembers()}
        inner = {"/".join(m.name.split("/")[1:2]) for m in t.getmembers() if m.isdir()}
    if len(tops) != 1 or not {"sys", "site"} <= inner:
        problems.append("%s: %s holds %s at its top and %s inside, wanting one folder with "
                        "sys and site in it" % (tag, tars[0], sorted(tops), sorted(inner)))
    size, last = 0, b""
    with gzip.open(os.path.join(directory, disk[0])) as f:
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            size += len(chunk)
            last = (last + chunk)[-512:]
    if machine == "quux":
        if not last.startswith(b"conectix"):
            problems.append("%s: %s does not uncompress to a VHD" % (tag, disk[0]))
    elif size not in (269562880, 70937600):
        problems.append("%s: %s uncompresses to %d bytes, not a T-300 or T-80 pack"
                        % (tag, disk[0], size))
    notes.append("%s: %s and %s do what the README says (%d bytes uncompressed)"
                 % (tag, disk[0], tars[0], size))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir", help="the directory the zips are in, or under")
    ap.add_argument("--commit", required=True, help="the commit the release was built from")
    ap.add_argument("--fault-commit", help="the fault bitstreams' commit, if not --commit")
    ap.add_argument("--root", default=".", help="this repository's root")
    ap.add_argument("--dtc", default=os.environ.get("DTC", "dtc"))
    ap.add_argument("--cadr-system", default="1003")
    ap.add_argument("--quux-system", default="2001")
    ap.add_argument("--cadr-assets")
    ap.add_argument("--quux-assets")
    args = ap.parse_args()
    commit = args.commit.lower()[:7]
    fault_commit = (args.fault_commit or args.commit).lower()[:7]
    if not re.fullmatch(r"[0-9a-f]{7}", commit) or not re.fullmatch(r"[0-9a-f]{7}", fault_commit):
        sys.exit("release_check: a commit is seven or more hexadecimal digits")
    if shutil.which(args.dtc) is None:
        sys.exit("release_check: no dtc (%s); give one with --dtc or DTC=" % args.dtc)

    found = {}
    for d, _, files in os.walk(args.dir):
        for f in files:
            if f.endswith(".zip"):
                found.setdefault(f, []).append(os.path.join(d, f))
    want = ["%s-%s.zip" % mb for mb in ZIPS]
    for f in sorted(found):
        if f not in want:
            problems.append("%s: not one of the release's seven zips" % found[f][0])
        elif len(found[f]) > 1:
            problems.append("%s: %d copies under %s" % (f, len(found[f]), args.dir))
    for f in want:
        if f not in found:
            problems.append("%s: missing" % f)

    faults, fabrics, notes = {}, {}, []
    for machine, board in ZIPS:
        name = "%s-%s.zip" % (machine, board)
        if name not in found:
            continue
        b = BOARDS[board]
        system = args.quux_system if machine == "quux" else args.cadr_system
        with tempfile.TemporaryDirectory() as tmp:
            with zipfile.ZipFile(found[name][0]) as z:
                z.extractall(tmp)
            def read(rel, binary=False):
                p = os.path.join(tmp, rel)
                if not os.path.isfile(p):
                    bad(name, "carries no %s" % rel)
                    return None
                return open(p, "rb" if binary else "r", errors=None if binary else "replace").read()
            fab = read("%s/%s" % (board, b["fabric"]), True)
            flt = read("%s/%s" % (board, b["fault"]), True)
            ids = []
            if fab is not None:
                s = identity(name, board, fab, "the machine's bitstream")
                if s is not None and s != commit + "0":
                    bad(name, "the machine's bitstream names build %s, wanting %s0 (commit %s, "
                        "clean tree)" % (s, commit, commit))
                fabrics[(machine, board)] = hashlib.sha256(fab).hexdigest()
                ids.append(s)
            if flt is not None:
                s = identity(name, board, flt, "the fault bitstream", fault=True)
                if s is not None and s != fault_commit + "4":
                    bad(name, "the fault bitstream names build %s, wanting %s4 (commit %s, "
                        "clean tree, the fault bitstream)" % (s, fault_commit, fault_commit))
                faults.setdefault(board, {})[machine] = hashlib.sha256(flt).hexdigest()
            if fab is not None and flt is not None and fab == flt:
                bad(name, "the machine's bitstream is the fault bitstream")
            node = reserved_node(args.root, board, machine)
            other = "cadr" if machine == "quux" else "quux13"
            if os.path.isfile(os.path.join(tmp, board, b["dtb"])):
                check_tree(name, args.dtc, os.path.join(tmp, board, b["dtb"]), node, other)
            else:
                bad(name, "carries no %s/%s" % (board, b["dtb"]))
            if b["loader"]:
                ld = read(b["loader"], True)
                # A node's name follows its FDT_BEGIN_NODE token, 00000001,
                # in every tree the loader carries; the Arty's carries two.
                if ld is not None:
                    begin = b"\0\0\0\x01"
                    if begin + node.encode() + b"\0" not in ld:
                        bad(name, "no tree in the loader (%s) reserves %s" % (b["loader"], node))
                    if re.search(re.escape(begin) + rb"%s@[0-9a-f]+\0" % other.encode(), ld):
                        bad(name, "a tree in the loader (%s) carries a %s@ node: it is the other "
                            "machine's" % (b["loader"], other))
            rc = read("fpgarc")
            if rc is not None:
                check_fpgarc(name, machine, board, rc)
            readme = read("README.TXT")
            if readme is not None:
                check_readme(name, machine, board, commit, system, readme)
            print("release_check: %-22s %s, %s; build %s; %s" % (
                name, machine, board, ids[0] if ids else "?", node))

    for board, by in sorted(faults.items()):
        if len(set(by.values())) > 1:
            problems.append("%s: the CADR's and QUUX's zips carry different fault bitstreams"
                            % board)
    for board in sorted({bd for _, bd in fabrics}):
        if ("cadr", board) in fabrics and fabrics.get(("quux", board)) == fabrics[("cadr", board)]:
            problems.append("%s: the CADR's and QUUX's zips carry the same bitstream" % board)

    for machine, d in (("cadr", args.cadr_assets), ("quux", args.quux_assets)):
        if d:
            check_assets(machine, d, notes)
    for n in notes:
        print("release_check: " + n)

    if problems:
        for p in problems:
            print("release_check: FAIL " + p)
        sys.exit("release_check: %d problem(s) in the release under %s" % (len(problems), args.dir))
    print("release_check: the seven zips are the release of %s: every bitstream's build, tree, "
          "loader, fpgarc and README as they should be" % commit)


if __name__ == "__main__":
    main()
