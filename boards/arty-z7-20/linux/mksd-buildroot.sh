#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Stage the card, and the TFTP server's directory, for the Buildroot image.
#
#     BIT=build/ddr/cadr_arty.bit boards/arty-z7-20/linux/mksd-buildroot.sh [PACKS="a.img 3=b.img"]
#
# The sibling of boards/arty-z7-20/linux/mksd.sh, which stages the stepping stone from
# Digilent's BSP and is left as it is.  This one takes what `make buildroot`
# built (output/images) and the bitstream it is told, and lays them out the
# way the board consumes them:
#
#     build/sd/buildroot/card/    BOOT.BIN u-boot.img uEnv.txt cadr.bit
#                                 zynq-arty-z7-20.dtb zImage rootfs.cpio.uboot
#                                                                     -> partition 1
#     build/sd/buildroot/packs/   disk-pack-0.img .. disk-pack-7.img   -> partition 2
#     build/sd/buildroot/server/  uEnv.net cadr.bit zynq-arty-z7-20.dtb
#                                 zImage rootfs.cpio.uboot            -> /srv/tftp
#     build/sd/buildroot/sdcard.img                                   -> dd, instead of both
#
# **THE CARD IS WRITTEN ONCE AND THEN NEVER LEAVES THE BOARD.**  That is what
# the second partition is for and it is why PACKS is optional: from the first
# boot onwards the ordinary way to put a pack on the card is to copy it to
# the running board --- `scp` over the network, or the board's own `tftp`
# client --- into /mnt/packs, where a file appearing IS a drive coming ready.
# Staging a pack here is for the first card and for a board with no network.
# docs/boot.md, "The drive bay", has the three gestures.
#
# PACKS names files to place, space separated.  An entry is `unit=path` or
# just `path`, which takes the lowest unit not yet spoken for; a pack lands
# as disk-pack-<unit>.img, which is the only thing that decides which drive
# it is.  PACKS_MB is how big partition 2 is made --- 3,584 MiB by default,
# thirteen T-300 packs, which fits any card of 4 GB and up.  A bigger card
# leaves the rest of itself unused, which costs nothing and is not worth a
# resize step at first boot; set PACKS_MB to the card you have if you want
# all of it.
#
# THE CARD CARRIES EVERYTHING AND BOOTS ON ITS OWN; the server directory is
# this project's convenience.  Which path the loader takes is decided by the
# card's uEnv.txt: with `serverip` set it fetches the five files over TFTP,
# without it reads them from the card (cadr.env).  So uEnv.txt is written
# from boards/arty-z7-20/linux/local.conf --- SERVERIP=a.b.c.d, ETHADDR=xx:xx:xx:xx:xx:xx, both
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
BOARD=boards/arty-z7-20/linux/buildroot/board/arty-z7-20
BIT=${BIT:-}
PACKS=${PACKS:-}
PACKS_MB=${PACKS_MB:-3584}
STANDALONE=${STANDALONE:-}
DTC=${DTC:-$HOSTBIN/dtc}

die() { echo "mksd-buildroot: $*" >&2; exit 1; }

for f in boot.bin u-boot.img zImage zynq-arty-z7-20.dtb rootfs.cpio.uboot; do
  [ -f "$IMAGES/$f" ] || die "no $f in $IMAGES: run 'make buildroot' first"
done
[ -n "$BIT" ] || die "BIT is not set: name the bitstream, e.g. BIT=build/ddr/cadr_arty.bit $0"
[ -f "$BIT" ] || die "no bitstream at $BIT"

# The drive bay, resolved before anything is written: which file goes on
# which unit, and whether they fit.  A pack is only a pack at exactly a
# T-300's or a T-80's size (boards/arty-z7-20/linux/buildroot/package/cadr-disk-packs/src/
# pack_bay.h), so a file of any other size is refused HERE rather than being
# staged and silently not being a drive on the board.
T300=269562880
T80=70937600
packs_total=0
pack_units=
pack_files=
next_unit=0
for entry in $PACKS; do
  case "$entry" in
    [0-7]=*) unit=${entry%%=*}; file=${entry#*=} ;;
    *=*)     die "PACKS entry '$entry': a unit is 0 to 7" ;;
    *)       file=$entry
             while echo " $pack_units " | grep -q " $next_unit "; do
               next_unit=$((next_unit + 1))
             done
             [ "$next_unit" -le 7 ] || die "PACKS names more than eight packs"
             unit=$next_unit ;;
  esac
  [ -f "$file" ] || die "no pack at $file"
  echo " $pack_units " | grep -q " $unit " && die "PACKS names unit $unit twice"
  size=$(stat -c %s "$file")
  [ "$size" = "$T300" ] || [ "$size" = "$T80" ] \
    || die "$file is $size bytes, which is neither a T-300 ($T300) nor a T-80 ($T80); it would not be a drive"
  pack_units="$pack_units $unit"
  pack_files="$pack_files $unit=$file"
  packs_total=$((packs_total + size))
done
# FAT32 needs a little room of its own; a megabyte a pack is generous.
packs_need=$(( packs_total / 1048576 + 8 ))
[ "$PACKS_MB" -ge "$packs_need" ] \
  || die "PACKS_MB=$PACKS_MB is too small for the packs named ($packs_need MiB needed)"
[ "$PACKS_MB" -ge 64 ] || die "PACKS_MB=$PACKS_MB: the pack partition is not worth making smaller than 64 MiB"

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
# The partition table an image carries, as shell assignments: two primary
# FAT32 partitions, the first bootable and at 1 MiB, not overlapping.  A
# layout that moved is a staging that fails here rather than a card that does
# not boot.
mbrinfo() {
  python3 - "$1" <<'PYMBR'
import struct, sys
b = open(sys.argv[1], "rb").read(512)
if b[510:512] != b"\x55\xaa":
    sys.exit("sdcard.img has no MBR signature")
out = []
for i in range(4):
    e = b[446 + 16 * i:446 + 16 * i + 16]
    if e[4] == 0:
        continue
    lba, n = struct.unpack("<II", e[8:16])
    out.append((e[0], e[4], lba, n))
if len(out) != 2:
    sys.exit("sdcard.img has %d partitions, wanting 2" % len(out))
(b1, t1, s1, n1), (b2, t2, s2, n2) = out
if t1 != 0x0c or t2 != 0x0c:
    sys.exit("the partitions are type 0x%02x and 0x%02x, wanting 0x0c twice" % (t1, t2))
if b1 != 0x80 or b2 != 0x00:
    sys.exit("the boot flags are 0x%02x and 0x%02x, wanting 0x80 and 0x00" % (b1, b2))
if s1 != 2048:
    sys.exit("partition 1 starts at sector %d, wanting 2048 (1 MiB)" % s1)
if s2 < s1 + n1:
    sys.exit("the two partitions overlap")
print("P1_OFF=%d P1_MB=%d P2_OFF=%d P2_MB=%d" % (s1 * 512, n1 // 2048, s2 * 512, n2 // 2048))
PYMBR
}

BITLINE=$(bitinfo "$BIT") || die "$BIT does not carry a Xilinx bitstream header"
echo "mksd-buildroot: bitstream $BIT"
echo "mksd-buildroot:   $BITLINE"

# The address and the MAC, from the file the repository does not carry.
SERVERIP=; ETHADDR=
if [ -r boards/arty-z7-20/linux/local.conf ]; then
  . boards/arty-z7-20/linux/local.conf
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
  echo "mksd-buildroot: WARNING: no ETHADDR in boards/arty-z7-20/linux/local.conf; the board will use a random MAC and U-Boot will say so" >&2
fi

rm -rf "$OUT"
mkdir -p "$OUT/card" "$OUT/packs" "$OUT/server"

# The card: everything.
cp "$IMAGES/boot.bin" "$OUT/card/BOOT.BIN"
cp "$IMAGES/u-boot.img" "$OUT/card/"
cp "$BIT" "$OUT/card/cadr.bit"
cp "$IMAGES/zynq-arty-z7-20.dtb" "$IMAGES/zImage" "$IMAGES/rootfs.cpio.uboot" "$OUT/card/"
sed -e "s/@SERVERIP@/${SERVERIP:-}/" -e "s/@ETHADDR@/${ETHADDR:-}/" \
    -e '/^serverip=$/d' -e '/^ethaddr=$/d' "$BOARD/uEnv.txt.in" > "$OUT/card/uEnv.txt"
grep -q '@' "$OUT/card/uEnv.txt" && die "uEnv.txt still carries a marker"

# The drive bay: nothing but packs, named by unit.  A hard link where the
# filesystem allows one, so that staging a 270 MB pack is not a copy.
for spec in $pack_files; do
  unit=${spec%%=*}; file=${spec#*=}
  cp -l "$file" "$OUT/packs/disk-pack-$unit.img" 2>/dev/null \
    || cp "$file" "$OUT/packs/disk-pack-$unit.img"
done

# **AND A README, WHICH IS NOT DECORATION.**  Two reasons, and the second is
# the one that makes it mandatory rather than nice.  First: this partition is
# what somebody sees when they put the card in a Windows machine, and a
# volume with nothing on it but a 270 MB `.img` explains nothing.  Second:
# genimage builds a FAT image by `mcopy`ing its mountpoint's contents, and an
# EMPTY directory makes that fail outright --- measured --- so a card staged
# with no pack would have no second partition at all, which is the ordinary
# case.  CRLF, because the reader is Notepad.
{
  printf 'The CADR disk pack drive bay.\r\n\r\n'
  printf 'This partition holds disk packs and nothing else.  Name a pack\r\n'
  printf 'disk-pack-0.img to disk-pack-7.img: the number is the disk unit the\r\n'
  printf 'machine sees it on, and whichever of the eight files exist are the\r\n'
  printf 'drives that are present.  A pack must be exactly 269,562,880 bytes\r\n'
  printf '(a T-300) or 70,937,600 (a T-80); any other size is not a pack.\r\n\r\n'
  printf 'While the board is running you need not take the card out at all:\r\n'
  printf '  copy a pack in            that drive comes ready\r\n'
  printf '  RENAME a pack out         that drive is taken away, and anything\r\n'
  printf '                            the machine had written is written into\r\n'
  printf '                            the file under its new name first\r\n'
  printf '  mark a pack read-only     that drive is write-protected\r\n\r\n'
  printf 'DELETING a pack loses whatever the machine had written and not yet\r\n'
  printf 'been given back; rename it instead.  Do not copy over a pack that is\r\n'
  printf 'in use --- rename the old one out first.\r\n\r\n'
  printf 'The other partition holds the loader and the boot files.  Do not\r\n'
  printf 'put packs there; nothing looks for them there.\r\n'
} > "$OUT/packs/README.TXT"

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

# The card as one image, if Buildroot built genimage: card/ becomes partition
# 1 and packs/ partition 2, each in whole.
if [ -x "$HOSTBIN/genimage" ]; then
  TMP=$(mktemp -d "${TMPDIR:-$HOME/.cache}/mksd-buildroot.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/tmp" "$TMP/in" "$TMP/root"
  # genimage takes one rootpath and reads each image's `mountpoint` under it,
  # so the two staged directories go side by side --- hard linked, so a
  # 270 MB pack is not copied a third time.
  cp -al "$OUT/card" "$TMP/root/card"
  cp -al "$OUT/packs" "$TMP/root/packs"
  CADR_PACKS_SIZE="${PACKS_MB}M" PATH="$HOSTBIN:$PATH" "$HOSTBIN/genimage" \
      --rootpath "$TMP/root" --tmppath "$TMP/tmp" \
      --inputpath "$TMP/in" --outputpath "$OUT" --config "$BOARD/genimage.cfg" >"$TMP/genimage.log" 2>&1 \
      || { cat "$TMP/genimage.log" >&2; die "genimage failed"; }
  rm -f "$OUT/boot.vfat" "$OUT/packs.vfat"
  # **THE PARTITION TABLE IS READ BACK, NOT ASSUMED.**  Two primary
  # partitions of type 0x0c, the first bootable at 1 MiB; the offsets come
  # out of the MBR the image actually carries, and are what the readback
  # below hands mtools --- so a layout that moved is a staging that fails
  # here rather than a card that does not boot.
  parts=$(mbrinfo "$OUT/sdcard.img" 2>&1) || die "$parts"
  eval "$parts"
  # Every file in card/ and packs/ is in the image, read back byte for byte
  # with mtools from its own partition --- the same bytes the boot ROM,
  # U-Boot and the disk pack program will read, not a listing.  A bay with no
  # pack in it is allowed, so the loop over packs/ may find nothing.
  if [ -x "$HOSTBIN/mcopy" ]; then
    for f in "$OUT"/card/*; do
      n=$(basename "$f")
      "$HOSTBIN/mcopy" -n -i "$OUT/sdcard.img@@$P1_OFF" "::$n" "$TMP/readback" 2>/dev/null \
        || die "$n is not in partition 1 of sdcard.img"
      cmp -s "$f" "$TMP/readback" || die "$n in sdcard.img differs from card/$n"
    done
    for f in "$OUT"/packs/*; do
      [ -e "$f" ] || continue
      n=$(basename "$f")
      "$HOSTBIN/mcopy" -n -i "$OUT/sdcard.img@@$P2_OFF" "::$n" "$TMP/readback" 2>/dev/null \
        || die "$n is not in partition 2 of sdcard.img"
      cmp -s "$f" "$TMP/readback" || die "$n in sdcard.img differs from packs/$n"
    done
    # And NOTHING BUT PACKS on partition 2: the program takes eight names, so
    # a ninth file there is a file nobody will ever read.
    for n in $("$HOSTBIN/mdir" -b -i "$OUT/sdcard.img@@$P2_OFF" :: 2>/dev/null | sed 's,^::/,,'); do
      case "$n" in
        disk-pack-[0-7].img|README.TXT) ;;
        *) die "partition 2 carries '$n', which is neither one of the eight pack names nor the README" ;;
      esac
    done
    rm -f "$TMP/readback"
  fi
else
  echo "mksd-buildroot: no genimage in $HOSTBIN; only the loose files are staged" >&2
fi

echo "staged $OUT"
echo "  $MODE"
(cd "$OUT/card" && for f in *; do printf '  card/    %-22s %10d  %s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -c1-16)"; done)
(cd "$OUT/packs" && for f in *; do [ -e "$f" ] || continue; printf '  packs/   %-22s %10d  %s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -c1-16)"; done)
(cd "$OUT/server" && for f in *; do printf '  server/  %-22s %10d  %s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -c1-16)"; done)
[ -f "$OUT/sdcard.img" ] && printf '  %-31s %10d  %s\n' sdcard.img "$(stat -c %s "$OUT/sdcard.img")" "$(sha256sum "$OUT/sdcard.img" | cut -c1-16)"
if [ -f "$OUT/sdcard.img" ]; then
  echo "  partition 1 at byte $P1_OFF, $P1_MB MiB, FAT32 BOOT   --- the loader and the boot files; Linux mounts it read-only"
  echo "  partition 2 at byte $P2_OFF, $P2_MB MiB, FAT32 PACKS  --- nothing but disk packs, at /mnt/packs, read-write"
fi
if [ -z "$PACKS" ]; then
  echo "  (no PACKS given: the bay is empty.  Copy a pack to the running board as"
  echo "   /mnt/packs/disk-pack-N.img and that unit's drive comes ready with no restart;"
  echo "   docs/boot.md, \"The drive bay\".)"
fi
exit 0
