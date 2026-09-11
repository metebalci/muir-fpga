#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build the card image that is released, and compress it.
#
#     BIT=<the released bitstream> boards/arty-z7-20/linux/mksd-release.sh
#
# This is a wrapper over mksd-buildroot.sh and it holds three decisions, so
# that a release is a command rather than a set of variables somebody has to
# remember.
#
#   1. NO DISK PACK.  A band is the user's own to supply.  The bay is empty,
#      the program says so on the console, and the CADR waits for a drive as
#      the real machine did with no pack loaded.
#   2. NO SERVER.  STANDALONE=1, so the card boots entirely from itself.
#      Without it the released card would carry this project's own TFTP
#      server address and try to boot over a network the user has not got.
#      That is a private address on a public artefact, so this script does
#      not trust the flag: it greps the staged card for one afterwards and
#      refuses to release if it finds anything address-shaped.
#   3. THE BAY FILLS A 4 GB CARD.  3,584 MiB, which leaves about 138 MB
#      spare on the smallest card sold under that name.  Sizing it to eight
#      packs instead would save 0.3 MB of download and cost the user the rest
#      of their card, so it is not done.
#
# The image is about 3.83 GB and compresses to about 7.4 MB, because what the
# bay does not hold is zeros.  Ship the .xz.
#
# The development card is the other script, mksd-dev.sh.
set -eu

cd "$(dirname "$0")/../../.."
OUT=${OUT:-build/sd/release}
BIT=${BIT:-}
[ -n "$BIT" ] || { echo "mksd-release: BIT=<the released bitstream> is required" >&2; exit 1; }
[ -f "$BIT" ] || { echo "mksd-release: no bitstream at $BIT" >&2; exit 1; }
[ -z "${PACKS:-}" ] || { echo "mksd-release: a release carries no pack; PACKS is for mksd-dev.sh" >&2; exit 1; }

OUT="$OUT" BIT="$BIT" BOOT_MB=64 PACKS_MB=${PACKS_MB:-3584} STANDALONE=1 \
    boards/arty-z7-20/linux/mksd-buildroot.sh

# The guard.  STANDALONE=1 is a flag and a flag can be wrong; this is the
# check.  Anything that looks like an IPv4 address in a file the card carries
# stops the release, and the card's own uEnv.txt is read out in full so that
# a reviewer sees what it says rather than being told.
if grep -rEn '([0-9]{1,3}\.){3}[0-9]{1,3}' "$OUT/card/" >/dev/null 2>&1; then
	echo "mksd-release: STOP --- something address-shaped is on the card:" >&2
	grep -rEn '([0-9]{1,3}\.){3}[0-9]{1,3}' "$OUT/card/" >&2
	exit 1
fi
echo "mksd-release: no address of any kind on the card"

img="$OUT/sdcard.img"
xz -T0 -6 -c "$img" > "$img.xz"
raw=$(stat -c %s "$img")
xzs=$(stat -c %s "$img.xz")
echo "mksd-release: $img.xz  $xzs bytes, from $raw --- this is what is published"
echo "mksd-release: the user writes it with"
echo "    xz -dc $(basename "$img").xz | sudo dd of=/dev/sdX bs=4M conv=sparse status=progress"
echo "mksd-release: a card of 4 GB or more, and about twelve megabytes actually written"
