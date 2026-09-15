#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build the card image that is released for a board, and compress it.
#
#     BIT=<the released bitstream> boards/arty-z7-20/linux/mksd-release.sh
#
#     IMAGES=$HOME/.cache/muir-fpga-buildroot/out-cora/images \
#     BOARD_DIR=boards/cora-z7-07s BOARD_DTB=zynq-cora-z7-07s.dtb \
#     BIT=<the Cora's released bitstream> boards/arty-z7-20/linux/mksd-release.sh
#
# **ONE RELEASE IMAGE A BOARD.**  The board enters this script the way it
# enters the staging script, in the same two variables, and both default to
# the Arty Z7-20's.  The image goes in a directory named for the board, so two
# boards' releases can be built one after the other without either being
# overwritten, and so that the published file says which board it is for.
#
# This is a wrapper over mksd-buildroot.sh and it holds four decisions, so
# that a release is a command rather than a set of variables somebody has to
# remember.
#
#   1. NO DISK PACK.  A band is the user's own to supply.  The bay is empty,
#      the program says so on the console, and the CADR waits for a drive as
#      the real machine did with no pack loaded.  **THE DEBUGGER'S BAND IS A
#      BAND TOO.**  CC compiled into a world is 257 MiB of somebody else's
#      Lisp on a public artifact, and the muirrc that names it would name a
#      file the user is free to delete, so a release carries neither.  The
#      mechanism is STANDALONE=1: mksd-buildroot.sh clears CC_PACK with the
#      four private values, and because it clears them BEFORE reading
#      local.conf as well, a CC_PACK in the environment cannot reach a
#      release either.  What ships instead is the muirrc that says how to
#      make one, with both of its last two lines commented.
#   2. NOTHING OF OURS ON IT.  STANDALONE=1, under which mksd-buildroot.sh
#      does not read local.conf at all: no TFTP server address, no MAC, no
#      Chaosnet peer, no bridge, and no Chaosnet station number of this
#      board's.  Without it the released card would try to boot over a network
#      the user has not got, would carry private values on a public artifact,
#      and would come out different on every build host.  **Not reading the
#      file is the structural half and it replaced a list of names**: every
#      card setting is read as `${VAR:-<default>}`, so local.conf could set any
#      of them and only six were ever cleared --- measured here, a release
#      built on this machine carried this board's own station number.  What is
#      still cleared by name is the environment, which a file cannot be asked
#      about.  This script does not trust the flag either: it greps both staged
#      partitions afterwards and refuses to release if it finds anything
#      address-shaped, an IP or a MAC.
#   3. THE PACK PARTITION SHIPS EMPTY AND IS THE WHOLE OF WHAT IS LEFT.
#      3,584 MiB, which leaves about 138 MB spare on the smallest card sold
#      as 4 GB.  What ships on it is a README.TXT saying what the partition
#      is for and how to name a pack, and the two files of flags --- `fpgarc`
#      for the CADR in the fabric and `muirrc` for the CADR inside muir ---
#      each the same full menu the development card gets, every flag present
#      under a sentence saying what it does.  Nothing else
#      is on it, and that is asserted below rather than assumed: a released
#      card with a band on it would be somebody else's Lisp world.
#   1a. AND ON A RELEASE THREE OF THOSE LINES ARE LIVE, WHICH IS WHAT
#      RELEASE=1 BELOW IS FOR.  `--chaos-address`, `--terminal` and
#      `--keyboard-boot`: the address switches, the screen, and the chord that
#      cold-boots the machine.  Everything else is present and commented out,
#      the Chaosnet cable and the serial line included.  A card cannot guess a
#      network the user has not described, and a release that plugged the
#      cable in would put a station on one and listen on a port nobody named;
#      a release that offered the serial line would open an unauthenticated
#      port on every interface for a cable hardly anybody wants.  Each is one
#      `#` away from being on and carries the sentence that says so.
#   4. IT FITS A 4 GB CARD, AND IT HAS ROOM FOR THREE PACKS.  Both are
#      asserted below against the smallest card sold under that name and
#      against three T-300s --- two drives and the debugger's band --- which
#      is what the user is being given room to copy in.  Sizing the bay to
#      eight packs instead would save 0.3 MB of download and cost the user the
#      rest of their card, so it is not done.
#
# WHAT THE USER DOES WITH IT.  Write the .xz to a card of 4 GB or more, put
# the card in the board, and switch it on: the loader takes the card path,
# because the uEnv.txt on it names no server, and Linux comes up with the CADR
# already in the fabric.  The machine then waits for a drive, because the bay
# is empty.  To give it one, put the card in a reader --- the pack partition is
# plain FAT32 and a PC can write it --- and copy a band in as
# disk-pack-0.img, or copy one to the running board over the network.  Either
# way the drive comes ready within a quarter second and nothing is restarted.
#
# The image is about 3.83 GB and compresses to about 7.4 MB, because what the
# bay does not hold is zeros.  Ship the .xz.
#
# The development card is the other script, mksd-dev.sh.
set -eu

cd "$(dirname "$0")/../../.."

# WHICH BOARD, passed straight through to mksd-buildroot.sh, which explains
# the two variables at its own defaults.  IMAGES is set for any board whose
# Buildroot output is not the default one.
BOARD_DIR=${BOARD_DIR:-boards/arty-z7-20}
BOARD_DTB=${BOARD_DTB:-zynq-arty-z7-20.dtb}
BOARD_NAME=$(basename "$BOARD_DIR")
[ -d "$BOARD_DIR" ] || { echo "mksd-release: no board directory at $BOARD_DIR" >&2; exit 1; }

OUT=${OUT:-build/sd/release/$BOARD_NAME}
BIT=${BIT:-}
[ -n "$BIT" ] || { echo "mksd-release: BIT=<the released bitstream> is required" >&2; exit 1; }
[ -f "$BIT" ] || { echo "mksd-release: no bitstream at $BIT" >&2; exit 1; }
[ -z "${PACKS:-}" ] || { echo "mksd-release: a release carries no pack; PACKS is for mksd-dev.sh" >&2; exit 1; }

# IMAGES is exported rather than written as an assignment prefix, for the
# reason mksd-dev.sh gives at the same line: a prefix that comes out of a
# parameter expansion is not an assignment, it is the command name.
[ -z "${IMAGES:-}" ] || export IMAGES

PACKS_MB=${PACKS_MB:-3584}
OUT="$OUT" BIT="$BIT" BOOT_MB=64 PACKS_MB="$PACKS_MB" STANDALONE=1 RELEASE=1 \
    BOARD_DIR="$BOARD_DIR" BOARD_DTB="$BOARD_DTB" \
    boards/arty-z7-20/linux/mksd-buildroot.sh

# The guard.  STANDALONE=1 is a flag and a flag can be wrong; this is the
# check.  Anything that looks like an address in a file the card carries stops
# the release.
#
# **IT READS BOTH PARTITIONS, AND IT USED TO READ ONE.**  When the only private
# value a card could hold was the TFTP server's address, card/uEnv.txt was the
# only place it could land and grepping card/ was the whole of it.  It is not
# any more: the two files of flags, fpgarc for the CADR in the fabric and
# muirrc for the CADR inside muir, are on the PACK partition and both can name
# a host on somebody's network.  A guard that reads
# the partition where the value cannot be and not the one where it can is a
# guard that passes for the wrong reason.
#
# **AND IT READS MAC ADDRESSES, WHICH IT ALSO USED NOT TO.**  uEnv.txt carries
# ethaddr from local.conf, and a MAC is not IPv4-shaped, so a MAC went straight
# past a check whose whole job is that nothing of ours is on a public artifact.
#
# **THE EXEMPTIONS ARE ADDRESSES THAT CANNOT NAME A HOST**, which is the only
# reason any of them is exempt.  This guard is about nothing of ours being on a
# public artifact, so what it has to let through is exactly the addresses that
# are somebody's nowhere:
#
#     0.0.0.0        "every interface on this board".  Both files of flags say
#                    it --- --terminal 0.0.0.0:5900, --serial 0.0.0.0:7641 ---
#                    because a bare port means the loopback and the screen
#                    would then be reachable only from the board itself, which
#                    is not what it is for.
#     127.0.0.1      the loopback, in the sentences that say how to keep the
#                    screen and the line to this board.  It is every machine's
#                    own address and is no machine's in particular.
#     192.0.2.x      RFC 5737's documentation ranges, TEST-NET-1, -2 and -3,
#     198.51.100.x   which IANA reserves so that an example can be written
#     203.0.113.x    without naming a real host.  The card's two commented
#                    example lines --- a Chaosnet peer and a bridge --- are
#                    written in TEST-NET-1 for exactly that reason.
#
# Anything else still stops the release, so 0.0.0.1, 10.0.0.0, a private
# 192.168 address and a MAC all do.
#
# **AND THIS STOPPED A RELEASE THAT WAS RIGHT, WHICH IS HOW THE LIST GREW.**
# When the card's file of flags became a full menu it gained the loopback in
# its prose and TEST-NET-1 in its two examples, and this guard exempted
# 0.0.0.0 alone --- so `mksd-release.sh` stopped on every board, naming four
# lines that were not private at all.  Nothing had run it since, which is why
# it sat broken: a guard nobody runs is a guard nobody knows is wrong.
#
# `grep -r` walks the board's own folder on the boot partition as well, which
# is what the card mirroring the server made necessary: the four files under
# it are binaries and carry no address, and a guard that stopped at the root
# of card/ would be reading one directory of two.
addrs=$(grep -rEoh \
		-e '([0-9]{1,3}\.){3}[0-9]{1,3}' \
		-e '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' \
		"$OUT/card/" "$OUT/packs/" 2>/dev/null \
		| grep -vxE '0\.0\.0\.0|127\.0\.0\.1|192\.0\.2\.[0-9]{1,3}|198\.51\.100\.[0-9]{1,3}|203\.0\.113\.[0-9]{1,3}' \
		| sort -u || true)
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
# address: a host name is as private as the number it resolves to and is not
# address-shaped.  Measured on this project's own development card, where the
# peer is a name --- the guard above passes it, and only STANDALONE clearing
# CHAOS_PEER keeps it off a release.  A flag can be wrong, which is the whole
# reason this file has a guard, so the two files of flags are asserted to name
# no station off this board.
#
# **THE BRIDGE IS A PEER FOR THIS PURPOSE.**  --chaos-udp-default-peer names
# no Chaosnet address, so it does not look like a peer line; it names a host
# on somebody's network all the same, which is the only thing this guard is
# about.  Both flags are looked for in both files.
for rc in "$OUT/packs/fpgarc" "$OUT/packs/muirrc"; do
	[ -f "$rc" ] || continue
	if grep -qE '^[[:space:]]*--chaos-udp-(default-)?peer' "$rc"; then
		echo "mksd-release: STOP --- $(basename "$rc") names a station off this board:" >&2
		grep -nE '^[[:space:]]*--chaos-udp-(default-)?peer' "$rc" >&2
		exit 1
	fi
done
echo "mksd-release: and no Chaosnet peer or bridge in either file of flags --- the network is the user's"

# **AND THE PACK PARTITION SHIPS EMPTY, WHICH IS A THIRD THING A FLAG CANNOT
# BE TRUSTED FOR.**  PACKS is refused above and STANDALONE clears CC_PACK, so
# two mechanisms already say no band ships; this reads the staged directory and
# says what is there.  A released card carrying somebody's Lisp world is the
# failure, and it would look exactly like a card that works.
for f in "$OUT"/packs/*; do
	[ -e "$f" ] || continue
	n=$(basename "$f")
	case "$n" in
		README.TXT|fpgarc|muirrc) ;;
		*) echo "mksd-release: STOP --- the pack partition carries '$n'; a release ships an empty bay" >&2; exit 1 ;;
	esac
done
for n in README.TXT fpgarc muirrc; do
	[ -s "$OUT/packs/$n" ] || { echo "mksd-release: STOP --- the pack partition has no $n" >&2; exit 1; }
done
echo "mksd-release: the bay is empty --- README.TXT, fpgarc and muirrc and nothing else"

# **AND IT FITS A CARD, WHICH IS ARITHMETIC NOBODY DOES AT THE MOMENT IT
# MATTERS.**  An image larger than the card does not warn, it fails part way:
# `dd` stops with "No space left on device", the boot partition is written
# because it comes first, and the pack partition is left truncated and
# claiming room the card has not got.  So the size is read off the image that
# was built and held against the smallest card sold as 4 GB --- 3,965,190,144
# bytes, which is what a card of that name really holds.
#
# The room the user is being given is three T-300 packs: two drives and the
# debugger's band, which is the arrangement docs/cc-pack.md describes.  That
# is 771 MiB, and the bay filling the card is far more; the assertion is here
# so that somebody who lowers PACKS_MB to save download finds out what it
# costs.
CARD_4GB=3965190144
T300=269562880
img="$OUT/sdcard.img"
[ -f "$img" ] || { echo "mksd-release: no image at $img; genimage did not run" >&2; exit 1; }
raw=$(stat -c %s "$img")
[ "$raw" -le "$CARD_4GB" ] \
	|| { echo "mksd-release: STOP --- the image is $raw bytes and the smallest 4 GB card is $CARD_4GB" >&2; exit 1; }
room_need=$(( (3 * T300) / 1048576 + 8 ))
[ "$PACKS_MB" -ge "$room_need" ] \
	|| { echo "mksd-release: STOP --- PACKS_MB=$PACKS_MB leaves no room for three T-300 packs ($room_need MiB)" >&2; exit 1; }
echo "mksd-release: $raw bytes fits a 4 GB card ($CARD_4GB), and the empty bay has room for"
echo "mksd-release: $PACKS_MB MiB of packs --- three T-300s are $room_need"

xz -T0 -6 -c "$img" > "$img.xz"
xzs=$(stat -c %s "$img.xz")
echo "mksd-release: $img.xz  $xzs bytes, from $raw --- this is what is published for the $BOARD_NAME"
echo "mksd-release: the user writes it with"
echo "    xz -dc $(basename "$img").xz | sudo dd of=/dev/sdX bs=4M status=progress"
echo "mksd-release: a card of 4 GB or more.  NOT conv=sparse: it skips runs of"
echo "mksd-release: zeros, so on a card that held something before, the parts of"
echo "mksd-release: a file that are legitimately zero keep the old bytes and the"
echo "mksd-release: card does not hold what the image says it holds"
