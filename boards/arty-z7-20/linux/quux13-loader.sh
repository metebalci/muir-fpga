#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX revision 13's U-Boot loader image, beside the one U-Boot's build made.
#
#     quux13-loader.sh <U-Boot's build directory> <board>
#
# `<board>` is arty-z7-20 or de25-nano.  Run in a Buildroot hook after U-Boot is
# built (`external.mk`), with PATH and the cross compiler as U-Boot's own build
# had them.  It writes `u-boot-quux13.img` (the Arty Z7-20) or
# `u-boot-quux13.itb` (the DE25-Nano) into the build directory.
#
# **WHY A SECOND LOADER.**  U-Boot's own tree carries the machine's
# reservation, and U-Boot places itself, the kernel's tree and the ramdisk
# with it: it runs while the bitstream it loaded is already live.  Revision 13
# reserves its own region, so a revision 13 card carries a loader whose tree
# is revision 13's (`quux13-reserved.dtsi`).  Everything else in the image is
# the build's.
#
# **HOW, WITH THE BUILD'S OWN COMMANDS.**  U-Boot records the command that
# made each file in `.<file>.cmd`.  This runs the one that compiled the board's
# tree with revision 13's name in place of the board's, then the one that made
# the loader with revision 13's tree in place of the board's, and nothing else
# changed:
#
#   - the Arty Z7-20's u-boot.img is `mkimage -f auto` over u-boot-nodtb.bin
#     and the tree (`.u-boot.img.cmd`).  Revision 13's tree is put at
#     quux13/zynq-arty-z7-20.dtb, so the FIT names it as the board's and the
#     first-stage loader's choice of configuration by that name is unchanged.
#   - the DE25-Nano's u-boot.itb is binman's (`..binman_stamp.cmd`), from the
#     tree's own description; revision 13's tree names itself as the tree to
#     pack (`socfpga_agilex5_de25_nano_quux13-u-boot.dtsi`), and binman is
#     given it as the description and its output directory as quux13/.
#
# Before either, the recorded command is run once as it stands into a scratch
# name and compared with the build's own loader, byte for byte with the build's
# timestamp: a recipe that did not reproduce the build's own image is refused
# rather than trusted with revision 13's.

set -eu
UB=${1:?the U-Boot build directory}
BOARD=${2:?the board}
cd "$UB"
die() { echo "quux13-loader: $*" >&2; exit 1; }

cmd_of() {
  # The recorded command, without Kbuild's `cmd_<target> :=`, and with its
  # one make variable, `$(pound)`, as make expanded it.
  [ -f "$1" ] || die "no $1 in $UB: U-Boot was not built here"
  head -1 "$1" | sed 's/^\(saved\)\{0,1\}cmd_[^ ]* := //; s/\$(pound)/#/g'
}

case "$BOARD" in
  arty-z7-20)
    TREE=zynq-arty-z7-20
    OUT=u-boot-quux13.img
    ;;
  de25-nano)
    TREE=socfpga_agilex5_de25_nano_cadr
    OUT=u-boot-quux13.itb
    ;;
  *) die "no revision 13 loader for $BOARD" ;;
esac
Q13=$(echo "$TREE" | sed 's/_cadr$//')
case "$BOARD" in
  arty-z7-20) Q13=${Q13}-quux13 ;;
  de25-nano) Q13=${Q13}_quux13 ;;
esac

# Revision 13's tree, by the command that built the board's with the board's
# name changed to revision 13's: the same preprocessor and compiler, the same
# include paths, and revision 13's -u-boot.dtsi appended where the board's is.
CMD=$(cmd_of "arch/arm/dts/.$TREE.dtb.cmd")
( eval "$(echo "$CMD" | sed "s/$TREE/$Q13/g")" ) || die "revision 13's tree did not compile"
[ -s "arch/arm/dts/$Q13.dtb" ] || die "U-Boot did not build arch/arm/dts/$Q13.dtb"
rm -rf quux13 quux13-check
mkdir -p quux13 quux13-check

# The build's own time, so that the recipe reproduces the build's image.
case "$BOARD" in
  arty-z7-20)
    CMD=$(cmd_of .u-boot.img.cmd)
    echo "$CMD" | grep -q " -b arch/arm/dts/$TREE.dtb " || die "u-boot.img's command names no arch/arm/dts/$TREE.dtb"
    STAMP=$(./tools/dumpimage -l u-boot.img | sed -n 's/^Created: *//p' | head -1)
    ;;
  de25-nano)
    CMD=$(cmd_of ..binman_stamp.cmd)
    echo "$CMD" | grep -q -- "-d ./u-boot.dtb -O \. " || die "binman's command is not the one this knows"
    STAMP=$(./tools/dumpimage -l u-boot.itb | sed -n 's/^Created: *//p' | head -1)
    ;;
esac
[ -n "$STAMP" ] || die "the build's loader carries no time"
SOURCE_DATE_EPOCH=$(date -d "$STAMP" +%s)
export SOURCE_DATE_EPOCH

case "$BOARD" in
  arty-z7-20)
    # The recipe, reproduced: the board's tree, into quux13-check/.
    eval "$(echo "$CMD" | sed 's| u-boot.img >| quux13-check/u-boot.img >|')"
    cmp -s u-boot.img quux13-check/u-boot.img || die "the recorded command did not reproduce u-boot.img"
    # And revision 13's.
    cp "arch/arm/dts/$Q13.dtb" "quux13/$TREE.dtb"
    # EVERY `-b`, which U-Boot's build gives twice, one configuration each:
    # a `g` substitution whose match ends in the space the next one begins
    # with replaced only the first, and the loader carried the board's tree
    # as its second configuration.  So one at a time until none is left.
    Q13CMD=$(echo "$CMD" | sed -e ":a" -e "s| -b arch/arm/dts/$TREE.dtb | -b quux13/$TREE.dtb |" -e "ta" \
                               -e "s| u-boot.img >| $OUT >|")
    ! echo "$Q13CMD" | grep -q -- "-b arch/arm/dts/$TREE.dtb" \
      || die "the loader's command still names the board's tree"
    eval "$Q13CMD"
    # And read back: each tree in it is revision 13's.  A tree's node names
    # are its strings, and the loader's code carries none of either.
    n=$(./tools/dumpimage -l "$OUT" | grep -c "Type: *Flat Device Tree" || true)
    q=$(strings -a "$OUT" | grep -c "^quux13@" || true)
    c=$(strings -a "$OUT" | grep -c "^cadr@" || true)
    [ "$n" -gt 0 ] && [ "$q" = "$n" ] && [ "$c" = 0 ] \
      || die "$OUT carries $n trees, $q of them revision 13's and $c the CADR's node"
    ;;
  de25-nano)
    eval "$(echo "$CMD" | sed 's|-d ./u-boot.dtb -O \. |-d ./u-boot.dtb -O quux13-check |')"
    cmp -s u-boot.itb quux13-check/u-boot.itb || die "the recorded command did not reproduce u-boot.itb"
    eval "$(echo "$CMD" | sed "s|-d ./u-boot.dtb -O \. |-d arch/arm/dts/$Q13.dtb -O quux13 |; s|default-dt=\"$TREE\"|default-dt=\"$Q13\"|")"
    [ -s quux13/u-boot.itb ] || die "binman made no quux13/u-boot.itb"
    cp quux13/u-boot.itb "$OUT"
    ;;
esac
[ -s "$OUT" ] || die "no $OUT was made"
echo "quux13-loader: $UB/$OUT, revision 13's tree $Q13, the recipe reproducing the build's own loader"
