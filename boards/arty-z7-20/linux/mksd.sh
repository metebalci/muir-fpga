#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Stage the microSD contents for Linux on the PS.
#
# Two directories come out, and the pair is the point: `stock` is the BSP
# exactly as Digilent shipped it, and `reserved` is the same thing plus a
# device tree that reserves the CADR's memory.  Booting stock first is what
# makes the reservation measurable --- 384 MB means nothing without a 512 MB
# reading from the same card to compare it against.
#
# Nothing here writes a card.  See docs/linux.md for that; it is a `dd` at a
# device node and it wants a human reading the device name.

set -eu

BSP=${BSP:-vendor/Petalinux-Arty-Z7-20-2017.4-1.bsp}
BSP_SHA=a83dbe29e3aa625ffb3d6c454c2e714046353f7dad774e244ac1a3bbbc225bf8
OUT=${OUT:-build/sd}
DTC=${DTC:-dtc}
FRAG=boards/arty-z7-20/linux/cadr-reserved.dtsi

die() { echo "mksd: $*" >&2; exit 1; }

[ -f "$BSP" ] || die "no BSP at $BSP.
  It is gitignored, like the pack archive, and is 100 MB from
  https://github.com/Digilent/Petalinux-Arty-Z7-20/releases/download/v2017.4-1/Petalinux-Arty-Z7-20-2017.4-1.bsp"

# Sum it before use, for the same reason the band's archive is summed: a
# vendored blob nobody checks is a blob that can change under a result.
echo "$BSP_SHA  $BSP" | sha256sum -c - >/dev/null 2>&1 \
  || die "$BSP does not match the recorded sha256 $BSP_SHA"

command -v "$DTC" >/dev/null 2>&1 || die "no dtc.
  Either 'sudo apt install device-tree-compiler', or point DTC at one:
  DTC=~/Xilinx/2026.1/Vivado/bin/dtc $0"

WORK=$(mktemp -d "${TMPDIR:-$HOME/.cache}/mksd.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

IMG=Arty-Z7-20/pre-built/linux/images
tar xzf "$BSP" -C "$WORK" "$IMG/BOOT.BIN" "$IMG/image.ub" "$IMG/system.dtb"
SRC=$WORK/$IMG

# The device tree, with the reservation appended.  dtc merges the two root
# definitions, so the fragment stays a fragment and the BSP's tree is never
# edited in place.  -p 0x1000 reproduces the BSP's own padding: both trees
# carry exactly 4096 bytes of slack after the string table.  That is fidelity
# to the BSP and not a functional requirement --- U-Boot's own fixup room is
# CONFIG_SYS_FDT_PAD, which boot_relocate_fdt adds by declaring a larger
# totalsize and writing PAST the blob, not into the slack inside it.  See
# docs/linux.md.
"$DTC" -I dtb -O dts -o "$WORK/base.dts" "$SRC/system.dtb" 2>/dev/null
cat "$WORK/base.dts" "$FRAG" > "$WORK/merged.dts"
"$DTC" -I dts -O dtb -p 0x1000 -o "$WORK/system-cadr.dtb" "$WORK/merged.dts" 2>/dev/null

# The check that makes the edit believable: decompile what we built and diff it
# against the BSP's own tree through the same decompiler.  Only the added node
# may differ.  Anything else means dtc moved something we did not ask it to.
"$DTC" -I dtb -O dts -o "$WORK/check.dts" "$WORK/system-cadr.dtb" 2>/dev/null
if ! diff "$WORK/base.dts" "$WORK/check.dts" > "$WORK/tree.diff"; then :; fi
if ! grep -q 'cadr@18000000' "$WORK/tree.diff"; then
  die "the reserved-memory node is not in the rebuilt tree"
fi
# `grep -c` has two failure modes and they need different answers.  With no
# match it prints 0 and exits 1, which `|| true` is enough for.  With a missing
# or unreadable file it prints NOTHING and exits 2 --- and an empty string
# reaching `[ "$REMOVED" -eq 0 ]` is a shell error about an illegal number, not
# the message this check exists to print.  An exit code cannot tell those two
# apart, so the value is checked before the numeric test can see it, and a
# non-number dies here saying so rather than four lines later saying something
# else.
countlines() {
  n=$(grep -c "$1" "$2" 2>/dev/null || true)
  case $n in
    '' | *[!0-9]*) die "cannot count '$1' in $2 --- grep gave \"$n\"" ;;
  esac
  echo "$n"
}

ADDED=$(countlines '^>' "$WORK/tree.diff")
REMOVED=$(countlines '^<' "$WORK/tree.diff")
[ "$REMOVED" -eq 0 ] || die "the rebuilt tree REMOVES $REMOVED lines; see $WORK/tree.diff"

rm -rf "$OUT"
mkdir -p "$OUT/stock" "$OUT/reserved"

# Stock: what Digilent shipped, and nothing else.  No uEnv.txt, so U-Boot runs
# its default_bootcmd and boots image.ub with the BSP's own device tree.
cp "$SRC/BOOT.BIN" "$SRC/image.ub" "$OUT/stock/"

# Reserved: the same card plus the one-line uEnv.txt that asks the TFTP server for
# the rest.  The rest --- our tree and the boot command --- goes in server/,
# which is what /srv/tftp holds.  The BSP's loose zImage is not staged: it is
# a different build from the kernel inside image.ub and dies under any tree
# (measured 10 Sep); netcmd boots the FIT's own kernel and ramdisk.
cp "$SRC/BOOT.BIN" "$SRC/image.ub" "$OUT/reserved/"
# The card's file carries the TFTP server's address, which is private: it is
# filled in here from boards/arty-z7-20/linux/local.conf (gitignored; `SERVERIP=a.b.c.d`), and
# the template is what the repository holds.
[ -r boards/arty-z7-20/linux/local.conf ] || die "boards/arty-z7-20/linux/local.conf is missing: put SERVERIP=<the TFTP server's address> in it"
. boards/arty-z7-20/linux/local.conf
[ -n "${SERVERIP:-}" ] || die "boards/arty-z7-20/linux/local.conf does not set SERVERIP"
sed "s/@SERVERIP@/$SERVERIP/" boards/arty-z7-20/linux/uEnv.txt.in > "$OUT/reserved/uEnv.txt"
grep -q '@SERVERIP@' "$OUT/reserved/uEnv.txt" && die "uEnv.txt still carries the marker"
mkdir -p "$OUT/server"
# The served tree drops Digilent's amba_pl --- the peripherals of the design
# cadr.bit displaces --- and keeps everything else, the reservation included.
"$DTC" -I dtb -O dts -o "$WORK/cadr.dts" "$WORK/system-cadr.dtb" 2>/dev/null
python3 - "$WORK/cadr.dts" "$WORK/nopl.dts" <<'PYEOF'
import sys
s=open(sys.argv[1]).read()
i=s.index('\n\tamba_pl {'); j=s.index('\n\t};',i)+4
open(sys.argv[2],'w').write(s[:i]+s[j:])
PYEOF
"$DTC" -I dts -O dtb -o "$OUT/server/system.dtb" "$WORK/nopl.dts" 2>/dev/null
grep -q amba_pl "$WORK/nopl.dts" && die "amba_pl survived the trim"
cp boards/arty-z7-20/linux/uEnv.net "$OUT/server/uEnv.net"

echo "staged $OUT"
printf '  stock/    %s\n' "$(cd "$OUT/stock" && ls | tr '\n' ' ')"
printf '  reserved/ %s\n' "$(cd "$OUT/reserved" && ls | tr '\n' ' ')"
printf '  server/   %s\n' "$(cd "$OUT/server" && ls | tr '\n' ' ')"
printf '  tree diff: %s lines added, %s removed\n' "$ADDED" "$REMOVED"
