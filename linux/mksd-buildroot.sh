#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Stage the card, and the TFTP server's directory, for the Buildroot image.
#
#     BIT=build/ddr/cadr_arty.bit linux/mksd-buildroot.sh [PACK=pack.img]
#
# The sibling of linux/mksd.sh, which stages the stepping stone from
# Digilent's BSP and is left as it is.  This one takes what `make buildroot`
# built (output/images) and the bitstream it is told, and lays them out the
# way the board consumes them:
#
#     build/sd/buildroot/card/    BOOT.BIN u-boot.img uEnv.txt cadr.bit
#                                 zynq-arty-z7-20.dtb zImage rootfs.cpio.uboot
#                                 [pack.img]                          -> the card
#     build/sd/buildroot/server/  uEnv.net cadr.bit zynq-arty-z7-20.dtb
#                                 zImage rootfs.cpio.uboot            -> /srv/tftp
#     build/sd/buildroot/sdcard.img                                   -> dd, instead of card/
#
# THE CARD CARRIES EVERYTHING AND BOOTS ON ITS OWN; the server directory is
# this project's convenience.  Which path the loader takes is decided by the
# card's uEnv.txt: with `serverip` set it fetches the five files over TFTP,
# without it reads them from the card (cadr.env).  So uEnv.txt is written
# from linux/local.conf --- SERVERIP=a.b.c.d, ETHADDR=xx:xx:xx:xx:xx:xx, both
# gitignored, both optional --- and STANDALONE=1 writes it without the server
# even when local.conf names one, for testing the card path here.
#
# THE BITSTREAM IS NAMED, NEVER GUESSED.  An earlier version took
# build/ddr/cadr_arty.bit if it existed, and what existed was a build a day
# older than the one being served.  BIT is mandatory, the file must exist,
# and its own header --- design, part, date, time, as Vivado wrote them ---
# is printed so the provenance is in the log of every staging.
#
# Nothing here writes a card.  sdcard.img is what the laptop dd's onto it,
# or the files in card/ go onto a FAT32 partition made by hand; both are the
# same card.

set -eu

IMAGES=${IMAGES:-$HOME/.cache/muir-fpga-buildroot/out/images}
HOSTBIN=${HOSTBIN:-$(dirname "$IMAGES")/host/bin}
OUT=${OUT:-build/sd/buildroot}
BOARD=linux/buildroot/board/arty-z7-20
BIT=${BIT:-}
PACK=${PACK:-}
STANDALONE=${STANDALONE:-}
DTC=${DTC:-$HOSTBIN/dtc}

die() { echo "mksd-buildroot: $*" >&2; exit 1; }

for f in boot.bin u-boot.img zImage zynq-arty-z7-20.dtb rootfs.cpio.uboot; do
  [ -f "$IMAGES/$f" ] || die "no $f in $IMAGES: run 'make buildroot' first"
done
[ -n "$BIT" ] || die "BIT is not set: name the bitstream, e.g. BIT=build/ddr/cadr_arty.bit $0"
[ -f "$BIT" ] || die "no bitstream at $BIT"
if [ -n "$PACK" ]; then
  [ -f "$PACK" ] || die "no pack at $PACK"
fi

# The bitstream's own header: Vivado writes the design name (with its
# UserID and Version), the part, the date and the time as tagged fields after
# a 13-byte preamble; 'e' introduces the configuration data and its length.
bitinfo() {
  python3 - "$1" <<'PYEOF'
import struct, sys
b = open(sys.argv[1], "rb").read(1024)
i = 0
n = struct.unpack(">H", b[i:i+2])[0]; i += 2 + n
i += 2
out = {}
while i < len(b):
    tag = chr(b[i]); i += 1
    if tag == "e":
        out["length"] = struct.unpack(">I", b[i:i+4])[0]
        break
    n = struct.unpack(">H", b[i:i+2])[0]; i += 2
    out[tag] = b[i:i+n].rstrip(b"\0").decode("ascii", "replace"); i += n
if "a" not in out or "length" not in out:
    sys.exit("not a Xilinx bitstream: no header fields")
print("design %s  part %s  date %s  time %s  %d bytes of configuration"
      % (out["a"], out.get("b", "?"), out.get("c", "?"), out.get("d", "?"),
         out["length"]))
PYEOF
}
BITLINE=$(bitinfo "$BIT") || die "$BIT does not carry a Xilinx bitstream header"
echo "mksd-buildroot: bitstream $BIT"
echo "mksd-buildroot:   $BITLINE"

# The address and the MAC, from the file the repository does not carry.
SERVERIP=; ETHADDR=
if [ -r linux/local.conf ]; then
  . linux/local.conf
fi
if [ -n "$STANDALONE" ]; then
  SERVERIP=
fi
if [ -n "${SERVERIP:-}" ]; then
  MODE="the network path: uEnv.txt names the TFTP server, the five files come from /srv/tftp"
else
  MODE="the card path: uEnv.txt names no server, the five files come from the card, no network is used"
fi
if [ -z "${ETHADDR:-}" ]; then
  echo "mksd-buildroot: WARNING: no ETHADDR in linux/local.conf; the board will use a random MAC and U-Boot will say so" >&2
fi

rm -rf "$OUT"
mkdir -p "$OUT/card" "$OUT/server"

# The card: everything.
cp "$IMAGES/boot.bin" "$OUT/card/BOOT.BIN"
cp "$IMAGES/u-boot.img" "$OUT/card/"
cp "$BIT" "$OUT/card/cadr.bit"
cp "$IMAGES/zynq-arty-z7-20.dtb" "$IMAGES/zImage" "$IMAGES/rootfs.cpio.uboot" "$OUT/card/"
[ -n "$PACK" ] && cp "$PACK" "$OUT/card/pack.img"
sed -e "s/@SERVERIP@/${SERVERIP:-}/" -e "s/@ETHADDR@/${ETHADDR:-}/" \
    -e '/^serverip=$/d' -e '/^ethaddr=$/d' "$BOARD/uEnv.txt.in" > "$OUT/card/uEnv.txt"
grep -q '@' "$OUT/card/uEnv.txt" && die "uEnv.txt still carries a marker"

# The server: the same five files and the command that fetches them.
cp "$BIT" "$OUT/server/cadr.bit"
cp "$IMAGES/zynq-arty-z7-20.dtb" "$IMAGES/zImage" "$IMAGES/rootfs.cpio.uboot" "$OUT/server/"
cp "$BOARD/uEnv.net" "$OUT/server/uEnv.net"

# What makes the staging believable rather than merely done.
#
# BOOT.BIN is a Zynq boot image: the boot ROM looks for "XNLX" at offset 0x24
# (UG585, the boot header's image identification), and a file that is not
# that is a board parked in its ROM.
id=$(dd if="$OUT/card/BOOT.BIN" bs=1 skip=36 count=4 2>/dev/null)
[ "$id" = "XNLX" ] || die "BOOT.BIN does not carry the boot ROM's XNLX identification at 0x24"
# u-boot.img is a FIT holding U-Boot proper and its tree --- the generic Zynq
# configuration's SPL loads a FIT (CONFIG_SPL_LOAD_FIT, no legacy-image
# support) and asks for it by that name (CONFIG_SPL_FS_LOAD_PAYLOAD_NAME) ---
# so it is a flattened tree whose /images node holds an image of type
# `firmware`.  Measured on the first build: mkimage -l prints nothing for it,
# which is why the check reads the FIT rather than trusting a listing.  And
# the U-Boot inside it must be the one whose environment boots this card:
# bootcmd=run cadr_boot with a cadr_card, or the card path does not exist.
if [ -x "$HOSTBIN/fdtget" ]; then
  found=no
  for img in $("$HOSTBIN/fdtget" -l "$OUT/card/u-boot.img" /images 2>/dev/null); do
    [ "$("$HOSTBIN/fdtget" "$OUT/card/u-boot.img" "/images/$img" type 2>/dev/null)" = firmware ] && found=yes
  done
  [ "$found" = yes ] || die "u-boot.img is not a FIT with a firmware image in it"
fi
for var in "bootcmd=run cadr_boot" "cadr_card=load mmc 0:1" "cadr_net=" "cadr_bootz="; do
  strings "$OUT/card/u-boot.img" | grep -q "^$var" || die "the U-Boot in u-boot.img has no '$var' in its environment"
done
if [ -x "$HOSTBIN/mkimage" ]; then
  "$HOSTBIN/mkimage" -l "$OUT/server/rootfs.cpio.uboot" | grep -q "RAMDisk" || die "rootfs.cpio.uboot is not a U-Boot ramdisk image"
fi
# The tree reserves the CADR's memory, no-map, and describes no PL
# peripheral: decompiled with the dtc Buildroot built, or one on the path.
command -v "$DTC" >/dev/null 2>&1 || DTC=dtc
if command -v "$DTC" >/dev/null 2>&1; then
  "$DTC" -I dtb -O dts -o "$OUT/tree.dts" "$OUT/card/zynq-arty-z7-20.dtb" 2>/dev/null
  grep -q 'cadr@18000000' "$OUT/tree.dts" || die "the tree has no cadr@18000000 node"
  grep -A4 'cadr@18000000' "$OUT/tree.dts" | grep -q 'no-map' || die "the tree's reservation is not no-map"
  grep -q 'amba_pl' "$OUT/tree.dts" && die "the tree describes PL peripherals"
  grep -q 'Zynq Arty Z7 Development Board' "$OUT/tree.dts" || die "the tree is not this board's"
else
  echo "mksd-buildroot: no dtc; the tree was not checked" >&2
fi
# The card and the server hold the same five files, byte for byte.
for f in cadr.bit zynq-arty-z7-20.dtb zImage rootfs.cpio.uboot; do
  cmp -s "$OUT/card/$f" "$OUT/server/$f" || die "$f differs between card/ and server/"
done

# The card as one image, if Buildroot built genimage: the whole card
# directory becomes the FAT partition, pack.img included when there is one.
if [ -x "$HOSTBIN/genimage" ]; then
  TMP=$(mktemp -d "${TMPDIR:-$HOME/.cache}/mksd-buildroot.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/tmp" "$TMP/in"
  PATH="$HOSTBIN:$PATH" "$HOSTBIN/genimage" --rootpath "$OUT/card" --tmppath "$TMP/tmp" \
      --inputpath "$TMP/in" --outputpath "$OUT" --config "$BOARD/genimage.cfg" >"$TMP/genimage.log" 2>&1 \
      || { cat "$TMP/genimage.log" >&2; die "genimage failed"; }
  rm -f "$OUT/boot.vfat"
  # Every file in card/ is in the image, read back byte for byte with mtools
  # from the partition at 1 MiB --- the same bytes the boot ROM and U-Boot
  # will read, not a listing.
  if [ -x "$HOSTBIN/mcopy" ]; then
    for f in "$OUT"/card/*; do
      n=$(basename "$f")
      "$HOSTBIN/mcopy" -n -i "$OUT/sdcard.img@@1M" "::$n" "$TMP/readback" 2>/dev/null || die "$n is not in sdcard.img"
      cmp -s "$f" "$TMP/readback" || die "$n in sdcard.img differs from card/$n"
    done
    rm -f "$TMP/readback"
  fi
else
  echo "mksd-buildroot: no genimage in $HOSTBIN; only the loose files are staged" >&2
fi

echo "staged $OUT"
echo "  $MODE"
(cd "$OUT/card" && for f in *; do printf '  card/    %-22s %10d  %s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -c1-16)"; done)
(cd "$OUT/server" && for f in *; do printf '  server/  %-22s %10d  %s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -c1-16)"; done)
[ -f "$OUT/sdcard.img" ] && printf '  %-31s %10d  %s\n' sdcard.img "$(stat -c %s "$OUT/sdcard.img")" "$(sha256sum "$OUT/sdcard.img" | cut -c1-16)"
[ -n "$PACK" ] || echo "  (no PACK given: the card has no pack.img; nothing writes one yet)"
exit 0
