#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The two files of this board's image that are made from other files: the
# CADR's device tree, and boot.scr.
#
# **THE TREE IS MAINLINE'S OWN KR260 TREE WITH THE CADR's ADDITIONS APPLIED.**
# The kernel builds zynqmp-smk-k26-revA-sck-kr-g-revB.dtb as mainline does,
# the SOM's tree with the carrier's overlay applied (BR2_LINUX_KERNEL_INTREE_
# DTS_NAME), and Buildroot copies it into images/.  This compiles our overlay,
# dts/xilinx/zynqmp-smk-k26-revA-sck-kr-g-revB-cadr.dts, which includes
# boards/kria-kr260/linux/cadr-reserved.dtsi, and applies it with
# fdtoverlay, the tool the kernel's own build applies the carrier's overlay
# with.  Nothing of the kernel's source is patched or copied.
#
# **AND THE RESULT IS READ BACK, NOT TRUSTED.**  fdtoverlay applies a fragment
# whose target path is missing by failing, which is what we want, but the
# check costs nothing: the region's node, its `reg` and `no-map`, the model,
# and the flash controller turned off, each read out of the blob with fdtget.
#
# **boot.scr IS boot.cmd WRAPPED BY mkimage** as a legacy script image, which
# U-Boot's distro boot runs with `source`.
#
# Run by Buildroot after the images are written (BR2_ROOTFS_POST_IMAGE_SCRIPT),
# with the images directory as $1 and HOST_DIR and BR2_EXTERNAL_CADR_KR260_PATH
# in the environment.

set -eu

IMAGES=${1:?post-image.sh: no images directory}
HOST=${HOST_DIR:?post-image.sh: no HOST_DIR}
EXT=${BR2_EXTERNAL_CADR_KR260_PATH:?post-image.sh: no BR2_EXTERNAL_CADR_KR260_PATH}
BOARD=$EXT/board/kria-kr260
BASE=zynqmp-smk-k26-revA-sck-kr-g-revB
TREE=$BASE-cadr

die() { echo "post-image.sh: $*" >&2; exit 1; }

[ -f "$IMAGES/$BASE.dtb" ] || die "no $BASE.dtb in $IMAGES: the kernel did not build mainline's KR260 tree"

"$HOST/bin/dtc" -@ -q -I dts -O dtb -i "$EXT/.." -o "$IMAGES/$TREE.dtbo" \
	"$BOARD/dts/xilinx/$TREE.dts" || die "the CADR's overlay does not compile"
"$HOST/bin/fdtoverlay" -i "$IMAGES/$BASE.dtb" -o "$IMAGES/$TREE.dtb" "$IMAGES/$TREE.dtbo" \
	|| die "the CADR's overlay does not apply to $BASE.dtb"
rm -f "$IMAGES/$TREE.dtbo"

get() { "$HOST/bin/fdtget" "$@" 2>/dev/null; }
reg=$(get -t x "$IMAGES/$TREE.dtb" /reserved-memory/cadr@60000000 reg) \
	|| die "$TREE.dtb has no /reserved-memory/cadr@60000000"
[ "$reg" = "0 60000000 0 8000000" ] || die "$TREE.dtb reserves '$reg', wanting 0 60000000 0 8000000"
get -l "$IMAGES/$TREE.dtb" /reserved-memory >/dev/null || die "no /reserved-memory"
get -p "$IMAGES/$TREE.dtb" /reserved-memory/cadr@60000000 | grep -qx no-map \
	|| die "the CADR's region in $TREE.dtb is not no-map"
[ "$(get "$IMAGES/$TREE.dtb" / model)" = "ZynqMP KR260 revB" ] || die "$TREE.dtb is not the KR260's tree"
[ "$(get "$IMAGES/$TREE.dtb" /axi/spi@ff0f0000 status)" = disabled ] \
	|| die "$TREE.dtb leaves the QSPI flash controller on"
echo "post-image.sh: $TREE.dtb: $BASE.dtb with the CADR's 128 MB at 0x60000000, no-map, and the QSPI controller off"

"$HOST/bin/mkimage" -A arm64 -O linux -T script -C none -n "the CADR on the Kria KR260" \
	-d "$BOARD/boot.cmd" "$IMAGES/boot.scr" >/dev/null || die "mkimage could not make boot.scr"
"$HOST/bin/mkimage" -l "$IMAGES/boot.scr" | grep -q 'Script' || die "boot.scr is not a script image"
echo "post-image.sh: boot.scr from boot.cmd"
