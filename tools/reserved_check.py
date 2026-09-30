#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Each machine's reserved-memory node, compiled, against where U-Boot puts things.

WHY THIS EXISTS.  `tools/mem_map_check.py` holds every written copy of the
memory map to the fabric's package, by reading the text.  Three things the
text cannot say:

  - that a machine's node COMPILES to what it says: a tree whose cells are
    counted wrong, whose `no-map` is misspelt, or which keeps the CADR's node
    beside revision 13's, reads the same to a regular expression and means
    something else to the kernel and to U-Boot;
  - that each machine's tree reaches its builds: the kernel's, U-Boot's, and
    the card's pairing of the tree with the machine's bitstream and loader;
  - that nothing U-Boot loads or places lands in the machine's region.  U-Boot
    runs with its own copy of the machine's tree and keeps its relocation and
    what it places clear of the node, while the bitstream it loaded is already
    live; the loads at the fixed addresses of its environment it does not move.

**EACH MACHINE HAS ITS OWN TREES** (docs/linux.md): the CADR's and QUUX
revision 12's reserve the CADR's 128 MB (`cadr-reserved.dtsi`); revision 13's
reserve from its main memory to the end of the disk pack program's records
(`quux13-reserved.dtsi`, after the CADR's, which it takes out), on the Arty
Z7-20 and the DE25-Nano.  A card carries one machine: its bitstream, its
kernel's tree under the board tree's name, and its loader, whose own tree is
the machine's.

WHAT IT DOES, machine by machine, with no board and no Buildroot:

  1. Wraps the machine's dtsi files in a skeleton of the board's root (its
     cell sizes, its memory, and on the DE25-Nano Altera's service-layer
     buffer), runs it through `cpp` as the kernel's and U-Boot's builds do,
     compiles it with `dtc` to a blob and back, and reads the node out of what
     `dtc` made: exactly one machine node, `no-map`, its unit address its
     base, its reg the package's region for that machine, inside the memory
     and clear of every other reserved node.
  2. Holds that the machine's trees reach its builds: the kernel's copy hook,
     U-Boot's list of tree files, revision 13's own tree including the board's
     and then its reservation, its -u-boot.dtsi including the board's, the
     hook that makes its loader, and the card script's REVISION=13 staging
     that tree and that loader.
  3. Reads U-Boot's environment for the board's fixed load addresses and
     models where U-Boot goes: into the highest free range that holds it
     (`RELOCATION_OWN`, measured), with the relocated tree and ramdisk just
     below it, in that range or below the region; on the DE25-Nano that is
     the top 128 MB whatever the tree says, which the region must leave.  No fixed load may
     be inside the region or U-Boot's own relocation, and the loads the kernel
     boots from may not be where the relocated tree and ramdisk go.
  4. With `--served-arty` or `--served-de25`, a board's served set, requires
     each file to fit the room its load has.

    python3 tools/reserved_check.py . [--dtc dtc] [--served-arty DIR]
                                      [--served-de25 DIR] [--stamp FILE]
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

MB = 1 << 20
DDR_MAP = "rtl/plumbing/cadr_ddr_map.sv"
MKSD = "boards/arty-z7-20/linux/mksd-buildroot.sh"
LOADER_SH = "boards/arty-z7-20/linux/quux13-loader.sh"

# How far below its top U-Boot's own relocation reaches on the Zynq boards,
# before it places the relocated tree and ramdisk under it: measured with the
# node at 0x1800_0000, the ramdisk at 0x155A_E000-0x15AC_377D and the tree at
# 0x155A_8000 (contract G2's D10), the ramdisk's end 37.2 MB down; rounded up
# to 44 MB.
RELOCATION_OWN = 44 * MB
# The top of the DE25-Nano's memory that U-Boot takes.
DE25_UBOOT_TOP = 128 * MB

FAMILIES = {
    "zynq": {
        "name": "the Zynq boards",
        "dir": "boards/arty-z7-20/linux",
        "defines": set(),
        # The root of zynq-7000.dtsi: one cell each, 512 MB of DDR3 at 0.
        "skeleton": ("/ {\n\t#address-cells = <1>;\n\t#size-cells = <1>;\n"
                     "\tmemory@0 {\n\t\tdevice_type = \"memory\";\n"
                     "\t\treg = <0x0 0x20000000>;\n\t};\n};\n"),
        "memory": (0x0, 0x2000_0000),
        # (defconfig, external.mk, the kernel's copy hook), a board a line.
        "builds": [
            ("boards/arty-z7-20/linux/buildroot/configs/arty_z7_20_defconfig",
             "boards/arty-z7-20/linux/buildroot/external.mk", "CADR_LINUX_COPY_RESERVED_DTSI"),
            ("boards/cora-z7-07s/linux/buildroot/configs/cora_z7_07s_defconfig",
             "boards/cora-z7-07s/linux/buildroot/external.mk",
             "CADR_CORA_LINUX_COPY_RESERVED_DTSI"),
        ],
        # Revision 13 runs on the first build's board alone.
        "quux13": {
            "defconfig": "boards/arty-z7-20/linux/buildroot/configs/arty_z7_20_defconfig",
            "external": "boards/arty-z7-20/linux/buildroot/external.mk",
            "dts": "boards/arty-z7-20/linux/buildroot/board/arty-z7-20/dts/xilinx/"
                   "zynq-arty-z7-20-quux13.dts",
            "board_dts": "zynq-arty-z7-20.dts",
            "uboot_dtsi": "boards/arty-z7-20/linux/buildroot/board/arty-z7-20/uboot/"
                          "zynq-arty-z7-20-quux13-u-boot.dtsi",
            "board_uboot_dtsi": "zynq-arty-z7-20-u-boot.dtsi",
            "loader": "u-boot-quux13.img",
            "arm": "arty-z7-20",
        },
        "env": "boards/arty-z7-20/linux/buildroot/board/arty-z7-20/uboot/cadr.env",
        # The loads, by their variables in the environment, each with the
        # most it may take, where it is less than the room to the next load,
        # and whether the boot needs it until the kernel starts.  cadr.env's
        # own table: cadr.bit is 4 MB; the ramdisk is given 64 MB, twelve
        # times the served one.
        "loads": {
            "cadr_uenv_addr": ("uEnv.txt, then uEnv.net", None, False),
            "cadr_bit_addr": ("cadr.bit", 4 * MB, False),
            "cadr_fdt_addr": ("the kernel's tree", 1 * MB, True),
            "cadr_kernel_addr": ("zImage", None, True),
            "cadr_ramdisk_addr": ("rootfs.cpio.uboot", 64 * MB, True),
        },
        "served": {"cadr_bit_addr": "cadr.bit", "cadr_fdt_addr": "zynq-arty-z7-20.dtb",
                   "cadr_kernel_addr": "zImage", "cadr_ramdisk_addr": "rootfs.cpio.uboot"},
        "relocation": "highest",
    },
    "de25": {
        "name": "the DE25-Nano",
        "dir": "boards/de25-nano/linux",
        "defines": {"CADR_DDR_MAP_DE25_NANO"},
        # socfpga_agilex5.dtsi's root and its reserved-memory node, with the
        # service layer's 32 MB at the base of the 1 GB.
        "skeleton": ("/ {\n\t#address-cells = <2>;\n\t#size-cells = <2>;\n"
                     "\tmemory@80000000 {\n\t\tdevice_type = \"memory\";\n"
                     "\t\treg = <0x0 0x80000000 0x0 0x40000000>;\n\t};\n"
                     "\treserved-memory {\n\t\t#address-cells = <2>;\n"
                     "\t\t#size-cells = <2>;\n\t\tranges;\n"
                     "\t\tsvcbuffer@0 {\n\t\t\treg = <0x0 0x80000000 0x0 0x2000000>;\n"
                     "\t\t\tno-map;\n\t\t};\n\t};\n};\n"),
        "memory": (0x8000_0000, 0x4000_0000),
        "builds": [
            ("boards/de25-nano/linux/buildroot/configs/de25_nano_defconfig",
             "boards/de25-nano/linux/buildroot/external.mk",
             "CADR_DE25_LINUX_COPY_RESERVED_DTSI"),
        ],
        "quux13": {
            "defconfig": "boards/de25-nano/linux/buildroot/configs/de25_nano_defconfig",
            "external": "boards/de25-nano/linux/buildroot/external.mk",
            "dts": "boards/de25-nano/linux/buildroot/board/de25-nano/dts/intel/"
                   "socfpga_agilex5_de25_nano_quux13.dts",
            "board_dts": "socfpga_agilex5_de25_nano_cadr.dts",
            "uboot_dtsi": "boards/de25-nano/linux/buildroot/board/de25-nano/uboot/"
                          "socfpga_agilex5_de25_nano_quux13-u-boot.dtsi",
            "board_uboot_dtsi": "socfpga_agilex5_de25_nano_cadr-u-boot.dtsi",
            "loader": "u-boot-quux13.itb",
            "arm": "de25-nano",
        },
        "env": "boards/de25-nano/linux/buildroot/board/de25-nano/uboot/cadr_de25.env",
        # cadr_de25.env's own table: the kernel up to 64 MB, the bitstream up
        # to 112 MB; the ramdisk, the last, is given 64 MB, twelve times the
        # served one.
        "loads": {
            "cadr_uenv_addr": ("uEnv.txt, then uEnv.net", None, False),
            "cadr_rbf_addr": ("cadr.core.rbf", None, False),
            "cadr_fdt_addr": ("the kernel's tree", 1 * MB, True),
            "cadr_kernel_addr": ("Image", None, True),
            "cadr_ramdisk_addr": ("rootfs.cpio.uboot", 64 * MB, True),
        },
        "served": {"cadr_rbf_addr": "cadr.core.rbf",
                   "cadr_fdt_addr": "socfpga_agilex5_de25_nano_cadr.dtb",
                   "cadr_kernel_addr": "Image", "cadr_ramdisk_addr": "rootfs.cpio.uboot"},
        # U-Boot relocates to the top 128 MB whatever the node says
        # (docs/linux.md), so the region must end below it.
        "relocation": "top",
    },
}

problems = []


def fail(msg):
    print("reserved: " + msg, file=sys.stderr)
    sys.exit(1)


def disagree(msg):
    problems.append(msg)
    print("reserved: " + msg, file=sys.stderr)


def read(root, path):
    p = os.path.join(root, path)
    if not os.path.exists(p):
        fail("%s is not there" % path)
    return open(p).read()


def regions_of(root, fam):
    """Each machine's region, (base, size), by `tools/mem_map_check.py`'s own
    reader of the package."""
    sys.path.insert(0, os.path.join(root, "tools"))
    import mem_map_check  # noqa: E402
    m = mem_map_check.ddr_map(read(root, DDR_MAP), FAMILIES[fam]["defines"])
    return {
        "cadr": (m["RESERVED_BASE"], m["RESERVED_MB"] * MB, "cadr"),
        "quux13": (m["QUUX13_MAIN_BASE"], m["QUUX13_RESERVED_END"] - m["QUUX13_MAIN_BASE"],
                   "quux13"),
    }


def compile_tree(root, fam, dtc, files):
    """The skeleton and `files` through cpp and dtc, and back to source."""
    f = FAMILIES[fam]
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "board.dts")
        with open(src, "w") as out:
            out.write("/dts-v1/;\n" + f["skeleton"])
            for name in files:
                out.write('#include "%s"\n' % name)
        pre = os.path.join(d, "board.pre.dts")
        inc = os.path.join(root, f["dir"])
        # The kernel's own cpp line for a tree (scripts/Makefile.lib, dtc_cpp_flags).
        r = subprocess.run(["cpp", "-nostdinc", "-I", inc, "-undef", "-D__DTS__",
                            "-x", "assembler-with-cpp", "-o", pre, src],
                           capture_output=True, text=True)
        if r.returncode:
            fail("%s: cpp refused the tree:\n%s" % (", ".join(files), r.stderr))
        blob = os.path.join(d, "board.dtb")
        r = subprocess.run([dtc, "-I", "dts", "-O", "dtb", "-o", blob, pre],
                           capture_output=True, text=True)
        if r.returncode:
            fail("%s: dtc refused the tree:\n%s" % (", ".join(files), r.stderr))
        r = subprocess.run([dtc, "-I", "dtb", "-O", "dts", blob], capture_output=True, text=True)
        if r.returncode:
            fail("dtc could not read back its own blob:\n%s" % r.stderr)
        return r.stdout


def node_body(text, name):
    """The body of the first node called `name`, and the offset it starts at."""
    m = re.search(r"(?m)^\s*%s\s*\{" % re.escape(name), text)
    if not m:
        return None, -1
    depth, i = 1, m.end()
    while depth and i < len(text):
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        i += 1
    return text[m.end():i - 1], m.start()


def cells(body, prop):
    m = re.search(r"(?<![\w#-])%s\s*=\s*<([^>]*)>" % re.escape(prop), body)
    return [int(c, 16) for c in m.group(1).split()] if m else None


def regions(reg, na, ns):
    out, step = [], na + ns
    for k in range(0, len(reg), step):
        a = 0
        for c in reg[k:k + na]:
            a = a << 32 | c
        n = 0
        for c in reg[k + na:k + step]:
            n = n << 32 | c
        out.append((a, n))
    return out


def check_compiled(fam, machine, dts, base, size, prefix):
    f = FAMILIES[fam]
    name = "%s, %s's tree" % (f["name"], machine)
    rm, rm_at = node_body(dts, "reserved-memory")
    if rm is None:
        disagree("%s: the compiled tree has no reserved-memory node" % name)
        return
    na, ns = cells(rm, "#address-cells"), cells(rm, "#size-cells")
    if not na or not ns:
        disagree("%s: reserved-memory states no cell sizes" % name)
        return
    na, ns = na[0], ns[0]
    nodes = re.findall(r"(?m)^\s*((?:cadr|quux13)@[0-9a-fA-F]+)\s*\{", dts)
    if len(nodes) != 1:
        disagree("%s: the compiled tree has %d machine nodes (%s), wanting one"
                 % (name, len(nodes), ", ".join(nodes)))
        return
    if not nodes[0].startswith(prefix + "@"):
        disagree("%s: its node is %s, not %s's" % (name, nodes[0], prefix))
    body, at = node_body(dts, nodes[0])
    if not (rm_at < at < rm_at + len("reserved-memory {") + len(rm)):
        disagree("%s: %s is not a child of reserved-memory" % (name, nodes[0]))
    if not re.search(r"(?m)^\s*no-map;", body):
        disagree("%s: %s is not no-map" % (name, nodes[0]))
    reg = cells(body, "reg")
    if not reg or len(reg) != na + ns:
        disagree("%s: %s's reg is %s, wanting %d cells" % (name, nodes[0], reg, na + ns))
        return
    (a, n), = regions(reg, na, ns)
    unit = int(nodes[0].split("@")[1], 16)
    if (a, n) != (base, size):
        disagree("%s: the compiled node reserves 0x%08X for 0x%X, the package 0x%08X for 0x%X"
                 % (name, a, n, base, size))
    if unit != a:
        disagree("%s: %s reserves from 0x%08X" % (name, nodes[0], a))
    lo, span = f["memory"]
    if a < lo or a + n > lo + span:
        disagree("%s: the region 0x%08X-0x%08X is not inside memory 0x%08X-0x%08X"
                 % (name, a, a + n - 1, lo, lo + span - 1))
    for other in re.findall(r"(?m)^\s*([\w-]+@[0-9a-fA-F]+)\s*\{", rm):
        if other == nodes[0]:
            continue
        ob, _ = node_body(rm, other)
        for oa, on in regions(cells(ob, "reg") or [], na, ns):
            if oa < a + n and a < oa + on:
                disagree("%s: the region meets %s at 0x%08X-0x%08X" % (name, other, oa,
                                                                      oa + on - 1))
    print("reserved: %-16s %-6s the compiled node: %s, 0x%08X-0x%08X, no-map"
          % (f["name"], machine, nodes[0], a, a + n - 1))


def uboot_dts_path(defconfig_text):
    m = re.findall(r'^BR2_TARGET_UBOOT_CUSTOM_DTS_PATH="([^"]*)"', defconfig_text, re.M)
    return m[0].split() if len(m) == 1 else []


def check_builds(root, fam):
    """Each machine's trees reach its builds, and the card pairs them."""
    f = FAMILIES[fam]
    for defconfig, external, hook in f["builds"]:
        paths = uboot_dts_path(read(root, defconfig))
        if not any(p.endswith("/../cadr-reserved.dtsi") for p in paths):
            disagree("%s: U-Boot's tree is not given cadr-reserved.dtsi" % defconfig)
        e = read(root, external)
        body = re.search(r"define %s\n(.*?)\nendef" % hook, e, re.S)
        if not body or "cp -f" not in body.group(1) or "CADR" not in body.group(1) \
                or not re.search(r"^LINUX_PRE_BUILD_HOOKS \+= %s$" % hook, e, re.M):
            disagree("%s: the kernel's tree is not given cadr-reserved.dtsi by %s" % (external, hook))
    q = f["quux13"]
    # Revision 13's own tree: the board's, then its reservation.
    dts = read(root, q["dts"])
    incs = re.findall(r'^#include "([^"]+)"', dts, re.M)
    if incs != [q["board_dts"], "quux13-reserved.dtsi"]:
        disagree("%s includes %s, wanting %s then quux13-reserved.dtsi"
                 % (q["dts"], incs, q["board_dts"]))
    if not re.search(r'^#include "%s"' % re.escape(q["board_uboot_dtsi"]),
                     read(root, q["uboot_dtsi"]), re.M):
        disagree("%s does not include %s" % (q["uboot_dtsi"], q["board_uboot_dtsi"]))
    paths = uboot_dts_path(read(root, q["defconfig"]))
    for want in (os.path.basename(q["dts"]), os.path.basename(q["uboot_dtsi"]),
                 "quux13-reserved.dtsi", q["board_dts"]):
        if not any(os.path.basename(p) == want for p in paths):
            disagree("%s: U-Boot is not given %s" % (q["defconfig"], want))
    e = read(root, q["external"])
    hooks = re.findall(r"define (\w+)\n(.*?)\nendef", e, re.S)
    if not any("quux13-reserved.dtsi" in b.replace("QUUX13_RESERVED_DTSI", "quux13-reserved.dtsi")
               or "QUUX13_RESERVED_DTSI" in b for n, b in hooks if "LINUX" in n):
        disagree("%s: the kernel's tree is not given quux13-reserved.dtsi" % q["external"])
    made = [n for n, b in hooks if "quux13-loader.sh" in b and q["arm"] in b]
    if not made or not re.search(r"^UBOOT_POST_BUILD_HOOKS \+= %s$" % made[0], e, re.M):
        disagree("%s: no U-Boot hook makes revision 13's loader for %s" % (q["external"], q["arm"]))
    if not any(q["loader"] in b and "BINARIES_DIR" in b for n, b in hooks):
        disagree("%s: no hook installs %s" % (q["external"], q["loader"]))
    # The card's pairing: REVISION=13 stages that tree and that loader.
    m = re.search(r'^case "\$REVISION" in\n(.*?)^esac', read(root, MKSD), re.S | re.M)
    arm = re.search(r"^\s*%s\)\s*$(.*?);;" % re.escape(q["arm"]), m.group(1) if m else "",
                    re.S | re.M)
    tree = os.path.basename(q["dts"])[:-4] + ".dtb"
    if not arm or not re.search(r"^\s*TREE_IMAGE=%s\s*$" % re.escape(tree), arm.group(1), re.M):
        disagree("%s: REVISION=13 on %s does not stage %s" % (MKSD, q["arm"], tree))
    if not arm or q["loader"] + ":" not in arm.group(1):
        disagree("%s: REVISION=13 on %s does not stage %s" % (MKSD, q["arm"], q["loader"]))


def env_addresses(root, fam):
    text = re.sub(r"/\*.*?\*/", "", read(root, FAMILIES[fam]["env"]), flags=re.S)
    out = {}
    for var in FAMILIES[fam]["loads"]:
        m = re.findall(r"^%s=(0x[0-9a-fA-F]+)\s*$" % var, text, re.M)
        if len(m) != 1:
            fail("%s sets %s %d times, wanting once" % (FAMILIES[fam]["env"], var, len(m)))
        out[var] = int(m[0], 16)
    return out


def meets(a, n, b, m):
    return a < b + m and b < a + n


def check_loads(root, fam, machine, base, size, served):
    f = FAMILIES[fam]
    name = "%s, %s" % (f["name"], machine)
    addr = env_addresses(root, fam)
    order = sorted(addr, key=addr.get)
    rooms = {}
    for k, var in enumerate(order):
        most = f["loads"][var][1]
        nxt = addr[order[k + 1]] - addr[var] if k + 1 < len(order) else None
        if nxt is None and most is None:
            fail("%s: %s is the last load and has no stated most" % (f["name"], var))
        rooms[var] = min(r for r in (nxt, most) if r is not None)
    placed = rooms["cadr_fdt_addr"] + rooms["cadr_ramdisk_addr"]
    lo, span = f["memory"]
    top = lo + span
    if f["relocation"] == "top" and base + size > top - DE25_UBOOT_TOP:
        # U-Boot relocates to the top whatever the tree says, so the region
        # must leave the top 128 MB.
        disagree("%s: the region ends at 0x%08X, inside U-Boot's top 128 MB from 0x%08X"
                 % (name, base + size - 1, top - DE25_UBOOT_TOP))
    # The highest free range that holds U-Boot: above the region if there is
    # room (on the DE25-Nano there always is), else below it; the relocated
    # tree and ramdisk just below U-Boot, in the same range if they fit, else
    # below the region.
    above = top - (base + size)
    if above >= RELOCATION_OWN:
        own = (top - RELOCATION_OWN, RELOCATION_OWN)
        rest = above - RELOCATION_OWN
        below = (own[0] - placed, placed) if rest >= placed else (base - placed, placed)
        where = "above the region"
    else:
        own = (base - RELOCATION_OWN, RELOCATION_OWN)
        below = (own[0] - placed, placed)
        where = "below the region"
    for var in order:
        what, most, kept = f["loads"][var]
        a, n = addr[var], rooms[var]
        if meets(a, n, base, size):
            disagree("%s: %s (%s) at 0x%08X, room to 0x%08X, is in the region 0x%08X-0x%08X"
                     % (name, what, var, a, a + n - 1, base, base + size - 1))
        elif meets(a, n, *own):
            disagree("%s: %s (%s) at 0x%08X, room to 0x%08X, is where U-Boot relocates, "
                     "0x%08X-0x%08X" % (name, what, var, a, a + n - 1, own[0], sum(own) - 1))
        elif kept and meets(a, n, *below):
            disagree("%s: %s (%s) at 0x%08X, room to 0x%08X, is where U-Boot places the "
                     "relocated tree and ramdisk, 0x%08X-0x%08X"
                     % (name, what, var, a, a + n - 1, below[0], sum(below) - 1))
        else:
            print("reserved: %-16s %-6s %-26s 0x%08X, %4d MB of room, clear"
                  % (f["name"], machine, what, a, n // MB))
        if served and var in f["served"]:
            p = os.path.join(served, f["served"][var])
            if os.path.exists(p) and os.path.getsize(p) > n:
                disagree("%s: the served %s is %d bytes and its room %d"
                         % (name, f["served"][var], os.path.getsize(p), n))
    print("reserved: %-16s %-6s U-Boot relocates %s, 0x%08X-0x%08X; the relocated tree and "
          "ramdisk at 0x%08X-0x%08X" % (f["name"], machine, where, own[0], sum(own) - 1,
                                        below[0], sum(below) - 1))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root")
    ap.add_argument("--dtc", default=os.environ.get("DTC", "dtc"))
    ap.add_argument("--served-arty", help="the Arty Z7-20's served set, to size its files")
    ap.add_argument("--served-de25", help="the DE25-Nano's served set, to size its files")
    ap.add_argument("--stamp")
    args = ap.parse_args()
    served = {"zynq": args.served_arty, "de25": args.served_de25}
    if not os.path.exists(os.path.join(args.root, LOADER_SH)):
        fail("%s is not there" % LOADER_SH)
    for fam in FAMILIES:
        machines = regions_of(args.root, fam)
        trees = {"cadr": ["cadr-reserved.dtsi"],
                 "quux13": ["cadr-reserved.dtsi", "quux13-reserved.dtsi"]}
        for machine, (base, size, prefix) in machines.items():
            dts = compile_tree(args.root, fam, args.dtc, trees[machine])
            check_compiled(fam, machine, dts, base, size, prefix)
            check_loads(args.root, fam, machine, base, size, served[fam])
        check_builds(args.root, fam)
    if problems:
        fail("%d problem(s) with the reserved regions" % len(problems))
    print("reserved: every machine's node compiles to its region, reaches its builds and its "
          "card, and nothing U-Boot loads or places is in it")
    if args.stamp:
        os.makedirs(os.path.dirname(args.stamp) or ".", exist_ok=True)
        open(args.stamp, "w").close()


if __name__ == "__main__":
    main()
