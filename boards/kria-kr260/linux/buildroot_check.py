#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# THE KRIA KR260's IMAGE IS BUILT FROM WHAT ITS FILES SAY, OR THE BUILD FAILS.
#
#     buildroot_check.py boot     <external tree>
#     buildroot_check.py qos      <external tree>
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
#   - every load address is below QUUX's region, which is the
#     lower of the two machines' (read out of cadr_board.h's KR260 half), and
#     clear of the SOM tree's two reserved regions and of the script's own
#     address; and `fdt_high` and `initrd_high` keep `booti` from moving the
#     tree and the ramdisk;
#   - nothing writes the flash or the loader's environment: no `saveenv`,
#     `env save`, `sf` or `fatwrite` anywhere in the script, the served file
#     or the card's template.
#
# **`qos`: HP0's QoS IS WRITTEN AT BOOT ON QUUX AND ON NOTHING ELSE.**  The overlay's /etc/init.d/S78quux15-qos is run under the host's
# POSIX shells against a stub `devmem` and a stub `cadr-console`, with
# cadr-common's real fault.sh and the overlay's real quux15-qos.sh: on QUUX
# both registers are written 0xF and read back; on the CADR, an older QUUX, a
# fabric the console does not know, the fault bitstream and an
# image with no console nothing is written.  And the overlay carries both
# files, executable, the defconfig names the overlay, and the hook runs before
# every package's init script.
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
    qos_built(tree, out)


def raster(tree):
    """**THE LINK PROGRAM'S MODE IS THE FABRIC'S RASTER.**  `cadr-displayport`
    writes the controller's main stream attributes from `dp_link.h`'s figures,
    and the fabric's display is built at `display_raster.mk`'s (held at the
    board's `u_display` by `tools/machine_param_check.py`).  A monitor shown a
    stream whose attributes are not the raster's shows nothing, or a picture
    moved, so the two are one."""
    root = os.path.abspath(os.path.join(tree, "..", "..", "..", ".."))
    mk = open(os.path.join(root, "boards", "kria-kr260", "display_raster.mk")).read()
    fabric = {k: int(v) for k, v in re.findall(r"-G(\w+)=(\d+)", mk)}
    hdr = open(os.path.join(root, "boards", "arty-z7-20", "linux", "buildroot", "package",
                            "cadr-displayport", "src", "dp_link.h")).read()
    prog = {k: int(v) for k, v in re.findall(r"^#define DP_([HV]_[A-Z]+)\s+(\d+)u", hdr, re.M)}
    if sorted(fabric) != sorted(prog) or len(fabric) != 8:
        die("the raster's figures are %s in display_raster.mk and %s in dp_link.h"
            % (sorted(fabric), sorted(prog)))
    for k in sorted(fabric):
        if fabric[k] != prog[k]:
            die("%s is %d in display_raster.mk and %d in cadr-displayport's dp_link.h"
                % (k, fabric[k], prog[k]))
    print("buildroot-kr260: cadr-displayport's mode is the fabric's raster, %dx%d"
          % (fabric["H_ACTIVE"], fabric["V_ACTIVE"]))


def programs(tree, bindir):
    """The programs in `bindir` say the KR260's addresses and ports, in their
    own --help and messages, which are compiled from the one map."""
    raster(tree)
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
        "quux-ethernet-device": ["skip %s guard" % want["CADR_BOARD_TALLY"]],
        # The DisplayPort link's program: the controller and the transceiver
        # where this board's map puts them, the console it follows, and the
        # board's mode.
        "cadr-displayport": ["the controller at 0x%s, the lane at 0x%s, the console at 0x%s"
                             % (want["CADR_BOARD_DISPLAYPORT_HEX"], want["CADR_BOARD_SERDES_HEX"],
                                want["CADR_BOARD_CONSOLE_HEX"]),
                             "1920x1080 at 60 Hz"],
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


# ------------------------------------------------------------ HP0's QoS hook
#
# The overlay's init script and the script it runs, as installed on the
# target, and the two registers (quux15-qos.sh's, UG1087's AFIFM2).
OVERLAY = "board/kria-kr260/rootfs-overlay"
QOS_HOOK = "etc/init.d/S78quux15-qos"
QOS_SCRIPT = "usr/sbin/quux15-qos.sh"
QOS_REGS = (0xFD380008, 0xFD38001C)
# The revision whose machine takes HP0 at 0xF: QUUX's, 16.
QOS_REVISIONS = (16,)
# The tally's two EMIO words, which fault.sh reads (cadr_board.h's KR260
# half), and the fault bitstream's word in them.
QOS_TALLY = (0xFF0A006C, 0xFF0A0070)
QOS_FALT = 0x46414C54

# `devmem` as BusyBox's applet answers: a write with three arguments, a read
# with two, printed as 0x and eight upper-case digits.  Each call is logged.
# The state is one file a register; a register named in $QOS_STUCK keeps 0
# whatever is written, which is a register that does not take the write.
QOS_DEVMEM = r"""#!/bin/sh
a=$(printf '%d' "$1") || exit 1
f="$QOS_STATE/$a"
if [ $# -ge 3 ]; then
	echo "W $1 $3" >> "$QOS_STATE/log"
	case " $QOS_STUCK " in *" $a "*) exit 0 ;; esac
	printf '%d\n' "$3" > "$f"
	exit 0
fi
echo "R $1" >> "$QOS_STATE/log"
v=0
[ -f "$f" ] && v=$(cat "$f")
printf '0x%08X\n' "$v"
"""

# `cadr-console machine [cadr|quux [REVISION]]` as console_face.c's
# cons_machine_word answers it, for the fabric $QOS_FABRIC names: `cadr`,
# `quux 13`, `quux 15`, or `unknown` (entry 21 neither machine's).  The
# identity line first, then 0 when the fabric is the machine asked for.
QOS_CONSOLE = r"""#!/bin/sh
echo "$*" >> "$QOS_STATE/console"
[ "$1" = machine ] || exit 2
want=${2:-} wrev=${3:-}
set -- $QOS_FABRIC
kind=$1 rev=${2:-}
case "$kind" in
cadr) echo "cadr-console: machine: CADR, 32-bit words; build 00000000 (commit 0000000, tree clean)" ;;
quux) echo "cadr-console: machine: QUUX revision $rev, MACHINE-ID 515800${rev}0 (revision $rev, processor type 0), 40-bit words; build 00000000 (commit 0000000, tree clean)" ;;
*) echo "cadr-console: machine: NOT KNOWN --- entry 21 reads 000000000000, neither QUUX's signature nor the CADR's answer"; exit 1 ;;
esac
[ -z "$want" ] && exit 0
if [ "$want" = "$kind" ] && { [ -z "$wrev" ] || [ "$wrev" = "$rev" ]; }; then
	exit 0
fi
echo "cadr-console: machine: NOT THE MACHINE ASKED FOR --- asked for $want $wrev, and the fabric is $kind $rev"
exit 1
"""


def qos_shells():
    """The shells the hook is run under, of those the build host has:
    BusyBox's ash, which is the board's, dash, and bash as a POSIX shell.
    **A BusyBox that prefers its own applets is left out and said**: it runs
    its `devmem` applet, not the stub on the PATH (Ubuntu's does), so it
    would test the build host's /dev/mem."""
    import shutil
    import subprocess
    out, skipped = [], []
    if shutil.which("busybox"):
        r = subprocess.run([shutil.which("busybox"), "sh", "-c", "command -v devmem"],
                           capture_output=True,
                           text=True, env=dict(os.environ, PATH="/nonexistent"))
        if r.stdout.strip() == "devmem":
            skipped.append("busybox (it prefers its own devmem applet to the stub)")
        else:
            out.append(["busybox", "sh"])
    if shutil.which("dash"):
        out.append(["dash"])
    if shutil.which("bash"):
        out.append(["bash", "--posix"])
    if not out:
        die("no busybox, dash or bash on this host: the QoS hook cannot be run here")
    for s in skipped:
        print("buildroot-kr260: the QoS hook is not run under " + s)
    return out


def qos_run(tree, shell, fabric, console=True, stuck=(), action="start"):
    """The overlay's hook run as `S78quux15-qos <action>` against a made-up
    board: `devmem` and `cadr-console` stubs on the PATH, cadr-common's real
    fault.sh with the KR260's tally, and the overlay's real quux15-qos.sh.
    Returns (status, output, writes, registers, console calls)."""
    import subprocess
    import tempfile
    overlay = os.path.join(tree, OVERLAY)
    hook = open(os.path.join(overlay, QOS_HOOK)).read()
    fault = os.path.join(tree, "..", "..", "..", "arty-z7-20", "linux", "buildroot",
                         "package", "cadr-common", "src", "fault.sh")
    with tempfile.TemporaryDirectory(prefix="kr260-qos-") as work:
        state = os.path.join(work, "state")
        bindir = os.path.join(work, "bin")
        os.makedirs(state)
        os.makedirs(bindir)
        open(os.path.join(state, "log"), "w").close()
        open(os.path.join(state, "console"), "w").close()
        stubs = {"devmem": QOS_DEVMEM}
        if console:
            stubs["cadr-console"] = QOS_CONSOLE
        for name, text in stubs.items():
            p = os.path.join(bindir, name)
            open(p, "w").write(text)
            os.chmod(p, 0o755)
        for a in QOS_TALLY:
            open(os.path.join(state, str(a)), "w").write(
                "%d\n" % (QOS_FALT if fabric == "fault" else 0x12345678))
        # fault.sh as cadr-common's Makefile installs it for this board.
        ftext = open(fault).read()
        if ftext.count("CADR_FAULT_BOARD=@CADR_BOARD@\n") != 1:
            die("%s: no single `CADR_FAULT_BOARD=@CADR_BOARD@` line to fill" % fault)
        open(os.path.join(work, "fault.sh"), "w").write(
            ftext.replace("CADR_FAULT_BOARD=@CADR_BOARD@\n", "CADR_FAULT_BOARD=kria-kr260\n"))
        # The hook's two paths on the target, pointed into the sandbox.  Each
        # must match exactly once, or this check names the line it lost.
        for old, new in (("FAULT_SH=/usr/share/cadr/fault.sh\n",
                          "FAULT_SH=%s/fault.sh\n" % work),
                         ("QOS_SH=/%s\n" % QOS_SCRIPT,
                          "QOS_SH=%s\n" % os.path.join(overlay, QOS_SCRIPT))):
            if hook.count(old) != 1:
                die("%s: the line %r is there %d time(s), wanting once"
                    % (QOS_HOOK, old.strip(), hook.count(old)))
            hook = hook.replace(old, new)
        hpath = os.path.join(work, "hook")
        open(hpath, "w").write(hook)
        env = dict(os.environ, PATH=bindir + ":/usr/bin:/bin", QOS_STATE=state,
                   QOS_FABRIC=fabric if fabric != "fault" else "cadr",
                   QOS_STUCK=" ".join(str(a) for a in stuck),
                   CADR_FAULT_SAID=os.path.join(work, "fault.said"))
        r = subprocess.run(shell + [hpath, action], env=env, capture_output=True,
                           text=True, timeout=60)
        writes = [l.split()[1:] for l in open(os.path.join(state, "log")).read().splitlines()
                  if l.startswith("W ")]
        regs = {}
        for a in QOS_REGS:
            p = os.path.join(state, str(a))
            regs[a] = int(open(p).read()) if os.path.isfile(p) else 0
        calls = open(os.path.join(state, "console")).read().splitlines()
        return r.returncode, r.stdout + r.stderr, writes, regs, calls


def qos(tree):
    """**HP0's QoS IS WRITTEN AT BOOT ON QUUX AND ON NOTHING ELSE** (contract
    G3 revision 15, A15b.5): the overlay's init script, run against stubs of
    `devmem` and of the fabric's identity, writes both registers to 0xF when
    `cadr-console machine quux 16` says the fabric is QUUX, and writes
    nothing at all on the CADR, on an older QUUX, on a fabric the console
    does not know, on the fault bitstream, or with no console program; and
    the image carries it, ahead of every daemon."""
    overlay = os.path.join(tree, OVERLAY)
    # The rootfs: the defconfig names this overlay, and the overlay holds the
    # hook and the script it runs, both executable.
    dc = settings(os.path.join(tree, DEFCONFIG))
    if dc.get("BR2_ROOTFS_OVERLAY") != '"$(BR2_EXTERNAL_CADR_KR260_PATH)/%s"' % OVERLAY:
        die("%s's BR2_ROOTFS_OVERLAY is %r, not this board's overlay"
            % (DEFCONFIG, dc.get("BR2_ROOTFS_OVERLAY")))
    for rel in (QOS_HOOK, QOS_SCRIPT):
        p = os.path.join(overlay, rel)
        if not os.path.isfile(p):
            die("no /%s in the image: %s is not in the overlay, so HP0's QoS is written"
                " at no fabric load" % (rel, p))
        if not os.stat(p).st_mode & 0o100:
            die("%s is not executable, and the overlay copies its mode to the target" % p)
    # Before every daemon of ours: its number below every package's init script.
    pkgs = os.path.join(tree, "..", "..", "..", "arty-z7-20", "linux", "buildroot", "package")
    nums = sorted((int(m.group(1)), n) for d in os.listdir(pkgs)
                  if os.path.isdir(os.path.join(pkgs, d))
                  for n in os.listdir(os.path.join(pkgs, d))
                  for m in [re.fullmatch(r"S(\d\d)[\w-]+", n)] if m)
    mine = int(re.match(r"etc/init\.d/S(\d\d)", QOS_HOOK).group(1))
    if not nums or mine >= nums[0][0]:
        die("%s runs at S%02d, not before %s, the first of the machine's daemons"
            % (QOS_HOOK, mine, nums[0][1] if nums else "(none found)"))

    shells = qos_shells()
    want15 = {a: 0xF for a in QOS_REGS}
    zero = {a: 0 for a in QOS_REGS}
    cases = 0
    for sh in shells:
        name = sh[0]
        # QUUX: both registers written 0xF, nothing else written, read back
        # and said.
        for rev in QOS_REVISIONS:
            st, out, writes, regs, calls = qos_run(tree, sh, "quux %d" % rev)
            cases += 1
            if regs != want15:
                die("%s, QUUX revision %d: HP0's QoS reads %s, wanting 0xF on both:"
                    % (name, rev, {hex(a): hex(v) for a, v in regs.items()}), out)
            if sorted(int(a, 16) for a, _ in writes) != sorted(QOS_REGS) or \
                    any(int(v, 0) != 0xF for _, v in writes):
                die("%s, QUUX revision %d: devmem wrote %s, wanting 0xF to each register once"
                    % (name, rev, writes), out)
            if "machine quux %d" % rev not in calls:
                die("%s, QUUX revision %d: the console was asked %s, not `machine quux %d`"
                    % (name, rev, calls, rev))
            if "quux15-qos: HP0 RDQOS 0x0000000F WRQOS 0x0000000F" not in out:
                die("%s, QUUX revision %d: the boot does not say what the registers read back:"
                    % (name, rev), out)
            if out.count("machine: QUUX revision %d" % rev) != 1:
                die("%s, QUUX revision %d: the boot does not print the identity line once:"
                    % (name, rev), out)
            if st != 0:
                die("%s, QUUX revision %d: the hook exited %d" % (name, rev, st), out)
        # Every other fabric: nothing written, the registers still 0.
        for fabric, console, why in (("cadr", True, "the CADR"),
                                     ("quux 13", True, "QUUX revision 13"),
                                     ("quux 15", True, "QUUX revision 15"),
                                     ("unknown", True, "a fabric the console does not know"),
                                     ("fault", True, "the fault bitstream"),
                                     ("quux 16", False, "no cadr-console on the image")):
            st, out, writes, regs, calls = qos_run(tree, sh, fabric, console=console)
            cases += 1
            if writes or regs != zero:
                die("%s, %s: devmem wrote %s and HP0's QoS reads %s; wanting nothing written"
                    " and 0" % (name, why, writes, {hex(a): hex(v) for a, v in regs.items()}),
                    out)
            if st != 0:
                die("%s, %s: the hook exited %d, and a boot goes on" % (name, why, st), out)
            if fabric == "fault" and calls:
                die("%s, the fault bitstream: the console was asked %s" % (name, calls))
        # A register that does not take the write is said, loudly.
        st, out, writes, regs, calls = qos_run(tree, sh, "quux 16", stuck=(QOS_REGS[1],))
        cases += 1
        if "NOT 0xF" not in out:
            die("%s, WRQOS not taking the write: the boot does not say so:" % name, out)
        # `stop` writes nothing.
        st, out, writes, regs, calls = qos_run(tree, sh, "quux 16", action="stop")
        cases += 1
        if writes or st != 0:
            die("%s, stop: devmem wrote %s, status %d" % (name, writes, st), out)
    print("buildroot-kr260: /%s runs /%s at S%02d, before %s: HP0's QoS reads 0xF on QUUX"
          " and nothing is written on the CADR, an older QUUX, an unknown fabric,"
          " the fault bitstream or with no console (%d cases, %s)"
          % (QOS_HOOK, QOS_SCRIPT, mine, nums[0][1], cases,
             " and ".join(s[0] for s in shells)))


def qos_built(tree, out):
    """The hook and its script in the built target, as the overlay has them."""
    for rel in (QOS_HOOK, QOS_SCRIPT):
        src = os.path.join(tree, OVERLAY, rel)
        got = os.path.join(out, "target", rel)
        if not os.path.isfile(got):
            die("no /%s in %s/target" % (rel, out))
        if open(got, "rb").read() != open(src, "rb").read():
            die("/%s in %s/target is not the overlay's %s" % (rel, out, src))
        if not os.stat(got).st_mode & 0o100:
            die("/%s in %s/target is not executable" % (rel, out))
    print("buildroot-kr260: the target carries /%s and /%s, as the overlay has them"
          % (QOS_HOOK, QOS_SCRIPT))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "boot":
        boot(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "qos":
        qos(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "configs":
        configs(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "programs":
        programs(sys.argv[2], sys.argv[3])
    else:
        die("usage: buildroot_check.py boot <tree> | qos <tree> | configs <tree> <output> "
            "| programs <tree> <directory>")


if __name__ == "__main__":
    main()
