#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# THE KRIA KR260's IMAGE IS BUILT FROM WHAT ITS FILES SAY, OR THE BUILD FAILS.
#
#     buildroot_check.py boot     <external tree>
#     buildroot_check.py configs  <external tree> <Buildroot output directory>
#     buildroot_check.py programs <external tree> <directory of programs>
#
# The DE25-Nano's check (boards/de25-nano/linux/buildroot_check.py) in this
# board's terms.
#
# **`boot`: THE CARD'S BOOT SCRIPT DOES WHAT ITS HEADER SAYS.**  This board
# runs the factory U-Boot, whose environment is not ours, so everything this
# project decides about the boot is in one script, board/kria-kr260/boot.cmd,
# and the served uEnv.net.  This holds, reading them as text:
#
#   - the script ends by running `cadr_boot`, and `cadr_boot` is a loop that
#     never ends: one attempt, a message, ten seconds, and another;
#   - each path loads the tree, the kernel and the root filesystem, then the
#     fabric, then boots, so that the machine is started by the last step
#     before `booti`, and each of the four files is named in the board's own
#     folder, `kria-kr260/`;
#   - the fabric falls back to the fault bitstream, on both paths;
#   - every load address is below QUUX revision 13's region, which is the
#     lower of the two machines' (read out of cadr_board.h's KR260 half), and
#     clear of the SOM tree's two reserved regions and of the script's own
#     address; and `fdt_high` and `initrd_high` keep `booti` from moving the
#     tree and the ramdisk;
#   - nothing writes the flash or the loader's environment: no `saveenv`,
#     `env save`, `sf` or `fatwrite` anywhere in the script, the served file
#     or the card's template.
#
# **`configs`, AFTER THE BUILD: every line we wrote holds**, the DE25-Nano's
# reason: Kconfig drops a line it cannot satisfy without a word.  The
# defconfig and the kernel's fragment are each held against the .config they
# were applied to, and the board's map against what cadr-common staged and
# what the image's programs say.
#
# **`programs`: the same question of programs built anywhere.**  `make check`
# compiles every program on the build host with the KR260's map and hands the
# directory here.
#
# **WHAT IT DOES NOT HOLD** is U-Boot's behavior.  It reads the script as text
# and does not run hush; the board's boot is what shows that it parses.

import os
import re
import sys

DEFCONFIG = "configs/kria_kr260_defconfig"
FRAGMENT = "board/kria-kr260/linux/linux.fragment"
BOOT_CMD = "board/kria-kr260/boot.cmd"
UENV_NET = "board/kria-kr260/uEnv.net"
UENV_TXT = "board/kria-kr260/uEnv.txt.in"
FOLDER = "kria-kr260/"
TREE = "zynqmp-smk-k26-revA-sck-kr-g-revB-cadr.dtb"
FILES = (TREE, "Image", "rootfs.cpio.uboot")
# The script's own load address in the factory environment (scriptaddr), and
# the room it is given.
SCRIPT_ADDR = 0x20000000
SCRIPT_ROOM = 0x01000000
# The SOM tree's reservations below the machines' regions, for the real-time
# cores (mainline's zynqmp.dtsi, rproc_0_fw_image and rproc_1_fw_image).
SOM_RESERVED = ((0x3ED00000, 0x40000), (0x3EF00000, 0x40000))
NEVER = ("saveenv", "env save", "sf ", "sf\t", "fatwrite", "mmc write", "usb write")


def die(*lines):
    for line in lines:
        print("buildroot-kr260: " + line, file=sys.stderr)
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


def header_path(tree):
    return os.path.join(tree, "..", "..", "..", "arty-z7-20", "linux", "buildroot",
                        "package", "cadr-common", "src", "cadr", "cadr_board.h")


def board_map(header):
    """The KR260's half of cadr_board.h, as {NAME: value}."""
    text = open(header).read()
    m = re.search(r"\n#else  // CADR_BOARD_KR260[^\n]*\n(.*?)\n#endif  // CADR_BOARD_KR260", text, re.S)
    if not m:
        die("%s has no CADR_BOARD_KR260 half" % header)
    out = {}
    for name, value in re.findall(r"^#define (CADR_BOARD_[A-Z0-9_]+)\s+(\S.*)$", m.group(1), re.M):
        out[name] = value.strip().strip('"')
    return out


def script_env(path):
    """boot.cmd's `setenv NAME 'VALUE'` and `setenv NAME VALUE` lines as
    {NAME: VALUE}, and its other commands in order."""
    env, cmds = {}, []
    for n, line in enumerate(open(path).read().splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = re.fullmatch(r"setenv (\w+) '([^']*)'", s) or re.fullmatch(r"setenv (\w+) (\S+)", s)
        if m:
            if m.group(1) in env:
                die("%s:%d sets %s a second time" % (path, n, m.group(1)))
            env[m.group(1)] = m.group(2)
        else:
            cmds.append(s)
    return env, cmds


def text_env(path):
    """An `env import -t` file's NAME=VALUE lines."""
    env = {}
    for line in open(path).read().splitlines():
        if line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        env[name] = value
    return env


def steps(value):
    """A `&&` chain's steps, stripped."""
    return [s.strip() for s in value.split("&&")]


def path_order(what, chain, fetch, fabric_step):
    """The three files fetched by `fetch`, each from the board's folder, then
    the fabric, then cadr_booti, and nothing after it."""
    want = []
    for s in chain:
        m = re.fullmatch(r"%s \$\{cadr_\w+_addr\} (\S+)" % fetch, s)
        if m:
            want.append(m.group(1))
    if sorted(want) != sorted(FOLDER + f for f in FILES):
        die("%s fetches %s, wanting %s" % (what, want, [FOLDER + f for f in FILES]))
    if chain[-2:] != [fabric_step, "run cadr_booti"]:
        die("%s does not end in `%s && run cadr_booti`: the fabric is not loaded last,"
            " just before the kernel" % (what, fabric_step),
            "    " + " && ".join(chain))
    if len(chain) != 5:
        die("%s has %d steps, wanting the three files, the fabric and booti" % (what, len(chain)))


def boot(tree):
    cmd = os.path.join(tree, BOOT_CMD)
    env, cmds = script_env(cmd)
    net = text_env(os.path.join(tree, UENV_NET))
    # The commands of all three, without their comments, which say these
    # words in order to say that they are not used.
    raw = "\n".join(l for p in (BOOT_CMD, UENV_NET, UENV_TXT)
                    for l in open(os.path.join(tree, p)).read().splitlines()
                    if not l.lstrip().startswith("#"))
    for word in NEVER:
        if word in raw:
            die("%r appears in the boot files: nothing here writes the flash or the"
                " loader's environment" % word.strip())

    # The loop, and the script ending in it.
    if not cmds or cmds[-1] != "run cadr_boot":
        die("%s does not end with `run cadr_boot`" % BOOT_CMD)
    loop = env.get("cadr_boot", "")
    if not re.fullmatch(r"while true; do run cadr_try; echo \"cadr: [^\"]*trying again[^\"]*\";"
                        r" sleep 10; done", loop):
        die("cadr_boot is not the loop `while true; do run cadr_try; echo ...; sleep 10; done`:",
            "    " + (loop or "(not defined)"))
    try_ = env.get("cadr_try", "")
    if not re.search(r'if test -n "\$\{serverip\}"; then .*run cadr_net; else run cadr_card; fi$', try_):
        die("cadr_try does not take the network path when uEnv.txt names a server"
            " and the card path otherwise:", "    " + try_)

    # The two paths: three files, the fabric, booti.
    path_order("cadr_card", steps(env.get("cadr_card", "")),
               r"load \$\{cadr_devtype\} \$\{cadr_devpart\}", "run cadr_fabric_card")
    path_order("uEnv.net's netcmd", steps(net.get("netcmd", "")), "tftpboot", "run cadr_fabric_net")
    if not re.search(r"tftpboot \$\{cadr_uenv_addr\} %suEnv\.net" % FOLDER, env.get("cadr_net", "")):
        die("cadr_net does not fetch %suEnv.net" % FOLDER)

    # The fabric and its fallback, on both paths.
    fab = env.get("cadr_fabric_card", "")
    if not re.fullmatch(r"if load \$\{cadr_devtype\} \$\{cadr_devpart\} \$\{cadr_bit_addr\} "
                        r"%scadr\.bit && fpga loadb 0 \$\{cadr_bit_addr\} \$\{filesize\}; "
                        r"then echo \"[^\"]*\"; else run cadr_fault_card; fi" % FOLDER, fab):
        die("cadr_fabric_card does not load %scadr.bit and fall back to cadr_fault_card:" % FOLDER,
            "    " + fab)
    if not re.search(r"load \$\{cadr_devtype\} \$\{cadr_devpart\} \$\{cadr_bit_addr\} "
                     r"%sfault\.bit && fpga loadb 0 \$\{cadr_bit_addr\} \$\{filesize\}$" % FOLDER,
                     env.get("cadr_fault_card", "")):
        die("cadr_fault_card does not load %sfault.bit" % FOLDER)
    fabnet = net.get("cadr_fabric_net", "")
    if not re.fullmatch(r"if tftpboot \$\{cadr_bit_addr\} %scadr\.bit && fpga loadb 0 "
                        r"\$\{cadr_bit_addr\} \$\{filesize\}; then echo \"[^\"]*\"; else echo "
                        r"\"[^\"]*\"; tftpboot \$\{cadr_bit_addr\} %sfault\.bit && fpga loadb 0 "
                        r"\$\{cadr_bit_addr\} \$\{filesize\}; fi" % (FOLDER, FOLDER), fabnet):
        die("uEnv.net's cadr_fabric_net does not load %scadr.bit and fall back to %sfault.bit:"
            % (FOLDER, FOLDER), "    " + fabnet)

    # booti, with the three addresses, and nothing moving them.
    if env.get("cadr_booti") != ("setenv bootargs ${cadr_bootargs} && booti ${cadr_kernel_addr}"
                                 " ${cadr_ramdisk_addr} ${cadr_fdt_addr}"):
        die("cadr_booti is not `booti` of the kernel, the ramdisk and the tree:",
            "    " + env.get("cadr_booti", "(not defined)"))
    for v in ("fdt_high", "initrd_high"):
        if env.get(v) != "0xffffffffffffffff":
            die("%s is %r: booti would place the tree or the ramdisk itself" % (v, env.get(v)))
    if "console=ttyPS1,115200" not in env.get("cadr_bootargs", ""):
        die("the kernel's console is not ttyPS1: %r" % env.get("cadr_bootargs"))
    if env.get("ethact") != "ethernet@ff0c0000":
        die("ethact is %r, not GEM1 (ethernet@ff0c0000), the J10C port" % env.get("ethact"))

    # Every load address below both machines' regions and clear of the SOM's
    # reservations and of the script itself.
    want = board_map(header_path(tree))
    floor = min(int(want["CADR_BOARD_QUUX13_MAIN_HEX"], 16), int(want["CADR_BOARD_RESERVED_HEX"], 16))
    addrs = {k: int(v, 16) for k, v in env.items() if re.fullmatch(r"cadr_\w+_addr", k)}
    if sorted(addrs) != ["cadr_bit_addr", "cadr_fdt_addr", "cadr_kernel_addr",
                         "cadr_ramdisk_addr", "cadr_uenv_addr"]:
        die("the load addresses are %s, wanting the bitstream, the tree, the kernel,"
            " the ramdisk and uEnv" % sorted(addrs))
    for k, a in sorted(addrs.items()):
        if a >= floor:
            die("%s=0x%08x is at or above 0x%08x, where the machines' regions begin" % (k, a, floor))
        for base, size in SOM_RESERVED + ((SCRIPT_ADDR, SCRIPT_ROOM),):
            if base <= a < base + size:
                die("%s=0x%08x is inside 0x%08x-0x%08x" % (k, a, base, base + size - 1))
    print("buildroot-kr260: boot.scr loops for ever, loads the tree, the kernel and the"
          " root filesystem from %s, then the fabric (falling back to fault.bit), then"
          " boots, on the card path and the network path" % FOLDER)
    print("buildroot-kr260: every load address is below 0x%08x and clear of the SOM's"
          " reservations; nothing writes the flash or the loader's environment" % floor)


def build_dir(out, pkg):
    build = os.path.join(out, "build")
    hits = [d for d in os.listdir(build) if re.fullmatch(re.escape(pkg) + r"-[0-9][0-9.]*", d)]
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
    print("buildroot-kr260: %s: all %d line(s) hold in the built .config" % (what, len(wanted)))


def configs(tree, out):
    hold(DEFCONFIG, settings(os.path.join(tree, DEFCONFIG)), os.path.join(out, ".config"))
    hold(FRAGMENT, settings(os.path.join(tree, FRAGMENT)),
         os.path.join(build_dir(out, "linux"), ".config"))
    staged = os.path.join(out, "staging", "usr", "include", "cadr", "cadr_board.h")
    if not os.path.isfile(staged):
        die("no %s: cadr-common staged no board map" % staged)
    first = open(staged).readline().strip()
    if first != "#define CADR_BOARD_KR260 1":
        die("the staged board map begins %r, not the KR260's define" % first)
    for f in ("boot.scr", TREE, "Image", "rootfs.cpio.uboot"):
        if not os.path.isfile(os.path.join(out, "images", f)):
            die("no %s in %s/images" % (f, out))
    programs(tree, os.path.join(out, "target", "usr", "bin"))


def programs(tree, bindir):
    """The programs in `bindir` say the KR260's addresses and ports, in their
    own --help and messages, which are compiled from the one map."""
    want = board_map(header_path(tree))
    # **THE CONNECTOR'S NAME IS HELD HERE AND NOT READ BACK**: the programs are
    # compared with the map, so a wrong name in the map would pass that
    # comparison.  It is the carrier's connector that the top level's `pmod1`
    # port and cadr_kr260.xdc's pins are on.
    if want.get("CADR_BOARD_DEBUG_CONNECTOR") != "PMOD1":
        die("the map names the debug cable's connector %r, wanting %r"
            % (want.get("CADR_BOARD_DEBUG_CONNECTOR"), "PMOD1"))
    said = {
        "cadr-console": ["(default 0x%s, the bottom of %s)"
                         % (want["CADR_BOARD_CONSOLE_HEX"], want["CADR_BOARD_CONSOLE_PORT"]),
                         want["CADR_BOARD_TALLY"] + " reads",
                         "a DEBUGGEE on %s," % want["CADR_BOARD_DEBUG_CONNECTOR"]],
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
        "quux-file-device": ["skip %s guard" % want["CADR_BOARD_TALLY"]],
    }
    for prog, texts in sorted(said.items()):
        path = os.path.join(bindir, prog)
        if not os.path.isfile(path):
            die("no %s in %s" % (prog, bindir))
        blob = open(path, "rb").read()
        for t in texts:
            if t.encode() not in blob:
                die("%s does not say %r: it was not built with this board's map" % (path, t))
    print("buildroot-kr260: all %d programs in %s carry the KR260's map "
          "(the console at 0x%s on %s, the display at 0x%s, %s)"
          % (len(said), bindir, want["CADR_BOARD_CONSOLE_HEX"],
             want["CADR_BOARD_CONSOLE_PORT"], want["CADR_BOARD_DISPLAY_HEX"],
             want["CADR_BOARD_TALLY"]))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "boot":
        boot(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "configs":
        configs(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "programs":
        programs(sys.argv[2], sys.argv[3])
    else:
        die("usage: buildroot_check.py boot <tree> | configs <tree> <output> "
            "| programs <tree> <directory>")


if __name__ == "__main__":
    main()
