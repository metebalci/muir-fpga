#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build the card image this project uses on its own board.
#
#     BIT=<a bitstream> boards/arty-z7-20/linux/mksd-dev.sh [PACKS="a.img 3=b.img"]
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
#   2. IT CARRIES PACKS.  Name them with PACKS and the machine boots straight
#      into its own world.  With none named the bay is empty, which is a valid
#      card and boots to a CADR with no drive.
#
# The pack partition is sized to what the packs need plus room for one more
# drive, so an image carrying one pack is about 594 MiB rather than filling a
# card.  Set PACKS_MB to fill the card instead, and the table in
# mksd-buildroot.sh's header says what each size takes.
set -eu

cd "$(dirname "$0")/../../.."
OUT=${OUT:-build/sd/buildroot}
BIT=${BIT:-}
[ -n "$BIT" ] || { echo "mksd-dev: BIT=<a bitstream> is required" >&2; exit 1; }
[ -f "$BIT" ] || { echo "mksd-dev: no bitstream at $BIT" >&2; exit 1; }

# A development card with no server is legal --- it is the card path, and the
# board boots from itself --- but it is not what this script is for, and
# somebody who has forgotten to write local.conf should be told rather than
# handed a card that quietly does something else.
if [ ! -r boards/arty-z7-20/linux/local.conf ]; then
	echo "mksd-dev: no boards/arty-z7-20/linux/local.conf, so this card would name no server" >&2
	echo "mksd-dev: write SERVERIP=<the TFTP server> and ETHADDR=<the board's MAC> there," >&2
	echo "mksd-dev: or use mksd-release.sh if a card that boots from itself is what you want" >&2
	exit 1
fi

OUT="$OUT" BIT="$BIT" BOOT_MB=${BOOT_MB:-64} PACKS="${PACKS:-}" \
    ${PACKS_MB:+PACKS_MB="$PACKS_MB"} \
    boards/arty-z7-20/linux/mksd-buildroot.sh

img="$OUT/sdcard.img"
echo "mksd-dev: $img  $(stat -c %s "$img") bytes"
echo "mksd-dev: write it with"
echo "    sudo dd if=$img of=/dev/sdX bs=4M conv=sparse status=progress"
echo "mksd-dev: and $OUT/server/ is what goes to the TFTP server's directory"
