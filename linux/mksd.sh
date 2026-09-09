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
FRAG=linux/cadr-reserved.dtsi

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
tar xzf "$BSP" -C "$WORK" "$IMG/BOOT.BIN" "$IMG/image.ub" "$IMG/zImage" "$IMG/system.dtb"
SRC=$WORK/$IMG

# The device tree, with the reservation appended.  dtc merges the two root
# definitions, so the fragment stays a fragment and the BSP's tree is never
# edited in place.  -p 0x1000 reproduces the BSP's own padding: both trees
# carry exactly 4096 bytes of slack after the string table, which is where
# U-Boot puts its fixups.
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
if grep -qE '^[<>]' "$WORK/tree.diff" | grep -qv 'reserved-memory\|cadr@\|address-cells\|size-cells\|ranges\|reg =\|no-map\|};\|^$'; then
  die "the rebuilt tree differs from the BSP's outside the added node; see $WORK/tree.diff"
fi
ADDED=$(grep -c '^>' "$WORK/tree.diff")
REMOVED=$(grep -c '^<' "$WORK/tree.diff" || true)
[ "$REMOVED" -eq 0 ] || die "the rebuilt tree REMOVES $REMOVED lines; see $WORK/tree.diff"

rm -rf "$OUT"
mkdir -p "$OUT/stock" "$OUT/reserved"

# Stock: what Digilent shipped, and nothing else.  No uEnv.txt, so U-Boot runs
# its default_bootcmd and boots image.ub with the BSP's own device tree.
cp "$SRC/BOOT.BIN" "$SRC/image.ub" "$OUT/stock/"

# Reserved: the same, plus a loose kernel and our tree, plus the uEnv.txt that
# makes U-Boot take them.
cp "$SRC/BOOT.BIN" "$SRC/image.ub" "$SRC/zImage" "$OUT/reserved/"
cp "$WORK/system-cadr.dtb" "$OUT/reserved/system.dtb"
cp linux/uEnv.txt "$OUT/reserved/uEnv.txt"

echo "staged $OUT"
printf '  stock/    %s\n' "$(cd "$OUT/stock" && ls | tr '\n' ' ')"
printf '  reserved/ %s\n' "$(cd "$OUT/reserved" && ls | tr '\n' ' ')"
printf '  tree diff: %s lines added, %s removed\n' "$ADDED" "$REMOVED"
