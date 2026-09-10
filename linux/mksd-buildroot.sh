#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Stage the card and the TFTP server's directory for the Buildroot image.
#
# The sibling of linux/mksd.sh, which stages the stepping stone from
# Digilent's BSP and is left as it is.  This one takes what `make buildroot`
# built (output/images) and lays it out the way the board consumes it:
#
#     build/sd/buildroot/card/     BOOT.BIN u-boot.img uEnv.txt     -> the card
#     build/sd/buildroot/server/   uEnv.net zImage zynq-arty-z7-20.dtb
#                                  rootfs.cpio.uboot [cadr.bit]     -> /srv/tftp
#     build/sd/buildroot/sdcard.img                                 -> dd, instead of the card/ files
#
# uEnv.txt carries the TFTP server's address and the board's MAC, both from
# linux/local.conf (gitignored: SERVERIP=a.b.c.d, ETHADDR=xx:xx:xx:xx:xx:xx),
# which is why this runs here and not inside Buildroot.  The bitstream is
# copied in as cadr.bit if BIT names one or build/ddr/cadr_arty.bit exists;
# otherwise the script says so and the server directory has to get it by
# hand, as docs/boot.md describes.
#
# Nothing here writes a card.  sdcard.img is what the laptop dd's onto it,
# or the three files in card/ go onto a FAT32 partition made by hand; both
# are the same card.

set -eu

IMAGES=${IMAGES:-$HOME/.cache/muir-fpga-buildroot/out/images}
HOSTBIN=${HOSTBIN:-$(dirname "$IMAGES")/host/bin}
OUT=${OUT:-build/sd/buildroot}
BOARD=linux/buildroot/board/arty-z7-20
BIT=${BIT:-build/ddr/cadr_arty.bit}
DTC=${DTC:-$HOSTBIN/dtc}

die() { echo "mksd-buildroot: $*" >&2; exit 1; }

for f in boot.bin u-boot.img zImage zynq-arty-z7-20.dtb rootfs.cpio.uboot; do
  [ -f "$IMAGES/$f" ] || die "no $f in $IMAGES: run 'make buildroot' first"
done

# The address and the MAC, from the file the repository does not carry.
[ -r linux/local.conf ] || die "linux/local.conf is missing: put SERVERIP=<the TFTP server's address> and ETHADDR=<the board's MAC> in it"
. linux/local.conf
[ -n "${SERVERIP:-}" ] || die "linux/local.conf does not set SERVERIP"
if [ -z "${ETHADDR:-}" ]; then
  echo "mksd-buildroot: WARNING: linux/local.conf does not set ETHADDR; the board will ask DHCP with a random MAC and U-Boot will say so" >&2
fi

rm -rf "$OUT"
mkdir -p "$OUT/card" "$OUT/server"

cp "$IMAGES/boot.bin" "$OUT/card/BOOT.BIN"
cp "$IMAGES/u-boot.img" "$OUT/card/"
if [ -n "${ETHADDR:-}" ]; then
  sed -e "s/@SERVERIP@/$SERVERIP/" -e "s/@ETHADDR@/$ETHADDR/" "$BOARD/uEnv.txt.in" > "$OUT/card/uEnv.txt"
else
  sed -e "s/@SERVERIP@/$SERVERIP/" -e "/@ETHADDR@/d" "$BOARD/uEnv.txt.in" > "$OUT/card/uEnv.txt"
fi
grep -q '@' "$OUT/card/uEnv.txt" && die "uEnv.txt still carries a marker"

cp "$IMAGES/zImage" "$IMAGES/zynq-arty-z7-20.dtb" "$IMAGES/rootfs.cpio.uboot" "$OUT/server/"
cp "$BOARD/uEnv.net" "$OUT/server/uEnv.net"
if [ -f "$BIT" ]; then
  cp "$BIT" "$OUT/server/cadr.bit"
else
  echo "mksd-buildroot: no bitstream at $BIT; copy the memory-on board's .bit to /srv/tftp/cadr.bit by hand (BIT=path selects another)" >&2
fi

# Three things that make the staging believable rather than merely done.
#
# boot.bin is a Zynq boot image: the boot ROM looks for "XNLX" at offset 0x24
# (UG585, the boot header's image identification), and a file that is not
# that is a board parked in its ROM.
id=$(dd if="$OUT/card/BOOT.BIN" bs=1 skip=36 count=4 2>/dev/null)
[ "$id" = "XNLX" ] || die "boot.bin does not carry the boot ROM's XNLX identification at 0x24"
# u-boot.img is a FIT holding U-Boot proper and its tree --- the generic Zynq
# configuration's SPL loads a FIT (CONFIG_SPL_LOAD_FIT, no legacy-image
# support) and asks for it by that name (CONFIG_SPL_FS_LOAD_PAYLOAD_NAME) ---
# so it is a flattened tree whose /images node holds an image of type
# `firmware` (U-Boot proper; `firmware-1` on the first build, beside the
# trees `fdt-1`/`fdt-2`).  Measured on that build: mkimage -l prints nothing
# for it, which is why the check reads the FIT rather than trusting a listing.
if [ -x "$HOSTBIN/fdtget" ]; then
  found=no
  for img in $("$HOSTBIN/fdtget" -l "$OUT/card/u-boot.img" /images 2>/dev/null); do
    [ "$("$HOSTBIN/fdtget" "$OUT/card/u-boot.img" "/images/$img" type 2>/dev/null)" = firmware ] && found=yes
  done
  [ "$found" = yes ] || die "u-boot.img is not a FIT with a firmware image in it"
fi
if [ -x "$HOSTBIN/mkimage" ]; then
  "$HOSTBIN/mkimage" -l "$OUT/server/rootfs.cpio.uboot" | grep -q "RAMDisk" || die "rootfs.cpio.uboot is not a U-Boot ramdisk image"
fi
# The served tree reserves the CADR's memory, no-map, and describes no PL
# peripheral: decompiled with the dtc Buildroot built, or one on the path.
command -v "$DTC" >/dev/null 2>&1 || DTC=dtc
if command -v "$DTC" >/dev/null 2>&1; then
  "$DTC" -I dtb -O dts -o "$OUT/tree.dts" "$OUT/server/zynq-arty-z7-20.dtb" 2>/dev/null
  grep -q 'cadr@18000000' "$OUT/tree.dts" || die "the served tree has no cadr@18000000 node"
  grep -A4 'cadr@18000000' "$OUT/tree.dts" | grep -q 'no-map' || die "the served tree's reservation is not no-map"
  grep -q 'amba_pl' "$OUT/tree.dts" && die "the served tree describes PL peripherals"
  grep -q 'Zynq Arty Z7 Development Board' "$OUT/tree.dts" || die "the served tree is not this board's"
else
  echo "mksd-buildroot: no dtc; the served tree was not checked" >&2
fi

# The card as one image, if Buildroot built genimage.
if [ -x "$HOSTBIN/genimage" ]; then
  TMP=$(mktemp -d "${TMPDIR:-$HOME/.cache}/mksd-buildroot.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/root" "$TMP/tmp"
  PATH="$HOSTBIN:$PATH" "$HOSTBIN/genimage" --rootpath "$TMP/root" --tmppath "$TMP/tmp" \
      --inputpath "$OUT/card" --outputpath "$OUT" --config "$BOARD/genimage.cfg" >"$TMP/genimage.log" 2>&1 \
      || { cat "$TMP/genimage.log" >&2; die "genimage failed"; }
  rm -f "$OUT/boot.vfat"
else
  echo "mksd-buildroot: no genimage in $HOSTBIN; only the loose files are staged" >&2
fi

echo "staged $OUT"
(cd "$OUT/card" && for f in *; do printf '  card/    %-22s %10d  %s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -c1-16)"; done)
(cd "$OUT/server" && for f in *; do printf '  server/  %-22s %10d  %s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -c1-16)"; done)
[ -f "$OUT/sdcard.img" ] && printf '  %-31s %10d  %s\n' sdcard.img "$(stat -c %s "$OUT/sdcard.img")" "$(sha256sum "$OUT/sdcard.img" | cut -c1-16)"
exit 0
