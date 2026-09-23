#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build the card this project uses on its own board.
#
#     BIT=<a bitstream> FAULT_BIT=<its fault bitstream> \
#         boards/arty-z7-20/linux/mksd-dev.sh [PACKS="a.img 3=b.img"]
#
# FAULT_BIT, or NO_FAULT=1, reaches mksd-buildroot.sh from the environment,
# which says what the fault bitstream is and why it is named.
#
# This is a wrapper over mksd-buildroot.sh and it is the opposite of
# mksd-release.sh in the two ways that matter.
#
#   1. IT NAMES THE SERVER.  local.conf supplies SERVERIP, so the card's
#      uEnv.txt sends the loader to the TFTP server for the bitstream, the
#      kernel, the tree and the root filesystem.  That is what makes the card
#      a one-time write here: everything after it changes by copying a file
#      to the server, and the board picks it up at the next reset.  local.conf
#      is gitignored and the address never reaches the repository.
#   2. IT CARRIES A BAND.  Name packs with PACKS and the band's two trees
#      with SYS and SITE, and the machine boots straight into its own world.
#      With none named the bay is empty, which is a valid card and boots to a
#      CADR with no drive.  A release carries none of the three and refuses
#      all three by name.
#
# The card is the same one partition as a release's, and it is made the same
# way: unpack the zip onto a card formatted as one FAT32 partition in an MBR.
# What differs is what is in it.
set -eu

cd "$(dirname "$0")/../../.."
OUT=${OUT:-build/sd/buildroot}
# WHICH BOARD, passed straight through to mksd-buildroot.sh, which explains
# the two variables at its own defaults.  Both default to the Arty Z7-20's,
# so a run that sets neither is the run this script has always been; the Cora
# Z7-07S sets all three, its images being in their own output directory.
#
#     IMAGES=$HOME/.cache/muir-fpga-buildroot/out-cora/images \
#     BOARD_DIR=boards/cora-z7-07s BOARD_DTB=zynq-cora-z7-07s.dtb \
#     BIT=<the Cora's .bit> boards/arty-z7-20/linux/mksd-dev.sh
BOARD_DIR=${BOARD_DIR:-boards/arty-z7-20}
BOARD_DTB=${BOARD_DTB:-zynq-arty-z7-20.dtb}
BOARD_NAME=$(basename "$BOARD_DIR")
BIT=${BIT:-}
[ -n "$BIT" ] || { echo "mksd-dev: BIT=<a bitstream> is required" >&2; exit 1; }
[ -f "$BIT" ] || { echo "mksd-dev: no bitstream at $BIT" >&2; exit 1; }

# A development card with no server is legal --- it is the card path, and the
# board boots from itself --- but it is not what this script is for, and
# somebody who has forgotten to write local.conf should be told rather than
# handed a card that quietly does something else.
if [ ! -r "$BOARD_DIR/linux/local.conf" ]; then
	echo "mksd-dev: no $BOARD_DIR/linux/local.conf, so this card would name no server" >&2
	echo "mksd-dev: write SERVERIP=<the TFTP server> and ETHADDR=<the board's MAC> there," >&2
	echo "mksd-dev: or use mksd-release.sh if a card that boots from itself is what you want" >&2
	exit 1
fi

# IMAGES is exported rather than written as an assignment prefix: a prefix
# that comes out of a parameter expansion is not an assignment, it is the
# command name, and `IMAGES=...: not found` is what that looks like.  SYS and
# SITE go the same way for the same reason.
[ -z "${IMAGES:-}" ] || export IMAGES
[ -z "${SYS:-}" ] || export SYS
[ -z "${SITE:-}" ] || export SITE
OUT="$OUT" BIT="$BIT" PACKS="${PACKS:-}" \
    BOARD_DIR="$BOARD_DIR" BOARD_DTB="$BOARD_DTB" \
    boards/arty-z7-20/linux/mksd-buildroot.sh

zip="$OUT/cadr-$BOARD_NAME.zip"
echo "mksd-dev: $zip  $(stat -c %s "$zip") bytes"
echo "mksd-dev: format a microSD card as ONE FAT32 partition in an MBR and unpack"
echo "mksd-dev: this onto it; $OUT/card/ is the same thing already unpacked"
echo "mksd-dev: and $OUT/server/$BOARD_NAME/ is what goes to this board's own"
echo "mksd-dev: directory on the TFTP server, /srv/tftp/$BOARD_NAME --- a directory a"
echo "mksd-dev: board, because every board's five files carry the same five names"
