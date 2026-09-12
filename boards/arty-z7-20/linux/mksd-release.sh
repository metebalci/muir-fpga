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
#   2. NOTHING OF OURS ON IT.  STANDALONE=1, which means the card carries
#      nothing from local.conf: no TFTP server address, no MAC, no Chaosnet
#      peer.  Without it the released card would try to boot over a network
#      the user has not got, and would carry three private values on a public
#      artefact.  This script does not trust the flag: it greps both staged
#      partitions afterwards and refuses to release if it finds anything
#      address-shaped, an IP or a MAC.
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
# check.  Anything that looks like an address in a file the card carries stops
# the release.
#
# **IT READS BOTH PARTITIONS, AND IT USED TO READ ONE.**  When the only private
# value a card could hold was the TFTP server's address, card/uEnv.txt was the
# only place it could land and grepping card/ was the whole of it.  It is not
# any more: the Chaosnet's peers file and muir's file of flags are on the PACK
# partition and both can name a host on somebody's network.  A guard that reads
# the partition where the value cannot be and not the one where it can is a
# guard that passes for the wrong reason.
#
# **AND IT READS MAC ADDRESSES, WHICH IT ALSO USED NOT TO.**  uEnv.txt carries
# ethaddr from local.conf, and a MAC is not IPv4-shaped, so a MAC went straight
# past a check whose whole job is that nothing of ours is on a public artefact.
#
# **0.0.0.0 IS THE ONE EXEMPTION AND IT IS NOT AN ADDRESS.**  muir's file of
# flags says --terminal 0.0.0.0:5901, which is "every interface on this board"
# and names no host anywhere; a bare port would mean the loopback and the
# screen would be reachable only from the board itself, which is not what it is
# for.  The exemption is that exact string and nothing else, so 0.0.0.1 or
# 10.0.0.0 still stops the release.
addrs=$(grep -rEoh \
		-e '([0-9]{1,3}\.){3}[0-9]{1,3}' \
		-e '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' \
		"$OUT/card/" "$OUT/packs/" 2>/dev/null | grep -vx '0\.0\.0\.0' | sort -u || true)
if [ -n "$addrs" ]; then
	echo "mksd-release: STOP --- something address-shaped is on the card:" >&2
	for a in $addrs; do
		grep -rEn -- "$a" "$OUT/card/" "$OUT/packs/" >&2 || true
	done
	exit 1
fi
echo "mksd-release: no address of any kind on either partition --- no IP, no MAC"

# **AND A PEER CAN BE A NAME, WHICH NO REGEX ABOVE CAN SEE.**  CHAOS_PEER is
# written `<address>@<host>:<port>` and the host may be a name as easily as an
# address: `chua.example.org` is as private as the number it resolves to and is
# not address-shaped.  Measured on this project's own development card, where
# the peer is a name --- the guard above passes it, and only STANDALONE
# clearing CHAOS_PEER keeps it off a release.  A flag can be wrong, which is
# the whole reason this file has a guard, so the two files that can carry a
# peer are asserted to carry none: the Chaosnet's peers file down to its
# comments, and muir's file of flags with no --chaos-udp-peer line in it.
peers=$OUT/packs/chaosnet.over.udp.peers.txt
if [ -f "$peers" ] && grep -qEv '^[[:space:]]*(#|$)' "$peers"; then
	echo "mksd-release: STOP --- the Chaosnet peers file names a peer:" >&2
	grep -nEv '^[[:space:]]*(#|$)' "$peers" >&2
	exit 1
fi
muirrc=$OUT/packs/muirrc
if [ -f "$muirrc" ] && grep -qE '^[[:space:]]*--chaos-udp-peer' "$muirrc"; then
	echo "mksd-release: STOP --- muir's file of flags names a Chaosnet peer:" >&2
	grep -nE '^[[:space:]]*--chaos-udp-peer' "$muirrc" >&2
	exit 1
fi
echo "mksd-release: and no Chaosnet peer in either file that can carry one --- the network is the user's"

img="$OUT/sdcard.img"
xz -T0 -6 -c "$img" > "$img.xz"
raw=$(stat -c %s "$img")
xzs=$(stat -c %s "$img.xz")
echo "mksd-release: $img.xz  $xzs bytes, from $raw --- this is what is published"
echo "mksd-release: the user writes it with"
echo "    xz -dc $(basename "$img").xz | sudo dd of=/dev/sdX bs=4M status=progress"
echo "mksd-release: a card of 4 GB or more.  NOT conv=sparse: it skips runs of"
echo "mksd-release: zeros, so on a card that held something before, the parts of"
echo "mksd-release: a file that are legitimately zero keep the old bytes and the"
echo "mksd-release: card does not hold what the image says it holds"
