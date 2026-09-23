#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build the zip that is released for a board.
#
#     BIT=<the released bitstream> FAULT_BIT=<its fault bitstream> \
#         boards/arty-z7-20/linux/mksd-release.sh
#
#     IMAGES=$HOME/.cache/muir-fpga-buildroot/out-cora/images \
#     BOARD_DIR=boards/cora-z7-07s BOARD_DTB=zynq-cora-z7-07s.dtb \
#     BIT=<the Cora's released bitstream> FAULT_BIT=<the Cora's fault bitstream> \
#         boards/arty-z7-20/linux/mksd-release.sh
#
# **ONE ZIP A BOARD, AND A RELEASE IS ALL OF THEM.**  The board enters this
# script the way it enters the staging script, in the same two variables, and
# both default to the Arty Z7-20's.  The zip goes in a directory named for the
# board and carries the board's name in its own name, so two boards' releases
# can be built one after the other without either being overwritten and so
# that a file somebody downloaded a month ago still says which board it is
# for.  `make release` runs this for every board in one command, which is what
# stops a release in which two boards were rebuilt and the third was not.
#
# **THERE IS NO CARD IMAGE.**  The user formats a microSD card themselves, as
# one FAT32 partition in an MBR, and unpacks the zip onto it.  The whole-card
# image this script used to build and compress is gone, and it is gone rather
# than kept beside the zip, because a second way that nothing exercises is a
# way that quietly stops working.  What went with it: the partition table, the
# `dd`, the warning about `conv=sparse`, the arithmetic that sized two
# partitions against the smallest card sold as 4 GB, and the check that the
# image fitted one.  What did NOT go is the readback --- the image used to be
# read back file by file out of each partition, and the zip is read back the
# same way in mksd-buildroot.sh --- or the digests, or any of the three guards
# below.
#
# This is a wrapper over mksd-buildroot.sh and it holds three decisions, so
# that a release is a command rather than a set of variables somebody has to
# remember.
#
#   1. NO DISK PACK AND NO BAND.  A band is the user's own to supply.  The bay
#      is empty, the program says so on the console, and the CADR waits for a
#      drive as the real machine did with no pack loaded.  **THE DEBUGGER'S
#      BAND IS A BAND TOO.**  CC compiled into a world is 257 MiB of somebody
#      else's Lisp on a public artifact, and the muirrc that names it would
#      name a file the user is free to delete, so a release carries neither.
#      The mechanism is STANDALONE=1: mksd-buildroot.sh clears CC_PACK with the
#      private values, and because it clears them BEFORE reading local.conf as
#      well, a CC_PACK in the environment cannot reach a release either.  What
#      ships instead is the muirrc that says how to make one, with both of its
#      last two lines commented.  **AND NO sys/ OR site/ EITHER**, for the same
#      reason: those are the band's Lisp files, and a release ships no band.
#      The two folders are on the card empty, which is what says where they go.
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
#      about.  This script does not trust the flag either: it greps the staged
#      card afterwards and refuses to release if it finds anything
#      address-shaped, an IP or a MAC.
#   3. AND THREE OF THE MENU'S LINES ARE LIVE, WHICH IS WHAT RELEASE=1 BELOW
#      IS FOR.  `--chaos-address`, `--terminal` and `--keyboard-boot`: the
#      address switches, the screen, and the chord that cold-boots the machine.
#      Everything else is present and commented out, the serial line included.
#      A card cannot guess a network the user has not described, and a release
#      that offered the serial line would open an unauthenticated port on every
#      interface for a cable hardly anybody wants.  Each is one `#` away from
#      being on and carries the sentence that says so.
#
# WHAT THE USER DOES WITH IT.  Format a microSD card as one FAT32 partition in
# an MBR, unpack the zip onto it, put the card in the board and switch it on:
# the loader takes the card path, because the uEnv.txt on it names no server,
# and Linux comes up with the CADR already in the fabric.  The machine then
# waits for a drive, because the bay is empty.  To give it one, put the card
# back in the reader and copy a band into `packs/` as `disk-pack-0.img`, or
# copy one to the running board over the network.  Either way the drive comes
# ready within a quarter second and nothing is restarted.
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
# A release always carries the fault bitstream: it is what a stranger's board
# shows when their card is wrong, and a release is for strangers.
FAULT_BIT=${FAULT_BIT:-}
[ -n "$FAULT_BIT" ] || { echo "mksd-release: FAULT_BIT=<the board's fault bitstream> is required" >&2; exit 1; }
[ -f "$FAULT_BIT" ] || { echo "mksd-release: no fault bitstream at $FAULT_BIT" >&2; exit 1; }
[ -z "${PACKS:-}" ] || { echo "mksd-release: a release carries no pack; PACKS is for mksd-dev.sh" >&2; exit 1; }
[ -z "${SYS:-}" ] && [ -z "${SITE:-}" ] \
  || { echo "mksd-release: a release carries no band, so no sys/ and no site/; SYS and SITE are for mksd-dev.sh" >&2; exit 1; }

# IMAGES is exported rather than written as an assignment prefix, for the
# reason mksd-dev.sh gives at the same line: a prefix that comes out of a
# parameter expansion is not an assignment, it is the command name.
[ -z "${IMAGES:-}" ] || export IMAGES

OUT="$OUT" BIT="$BIT" FAULT_BIT="$FAULT_BIT" NO_FAULT= STANDALONE=1 RELEASE=1 \
    BOARD_DIR="$BOARD_DIR" BOARD_DTB="$BOARD_DTB" \
    boards/arty-z7-20/linux/mksd-buildroot.sh

# The guard.  STANDALONE=1 is a flag and a flag can be wrong; this is the
# check.  Anything that looks like an address in a file the card carries stops
# the release.
#
# **IT READS THE WHOLE CARD, AND IT USED TO READ ONE PARTITION OF TWO.**  When
# the only private value a card could hold was the TFTP server's address,
# uEnv.txt was the only place it could land.  It is not any more: the two files
# of flags, fpgarc for the CADR in the fabric and muirrc for the CADR inside
# muir, both name a host on somebody's network, and they used to live on the
# other partition, which this guard did not read.  There is one partition now,
# so `grep -r` over the staged card is the whole of it and cannot be aimed at
# the wrong half.
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
# `grep -r` walks every folder on the card --- the board's own, and packs/,
# sys/ and site/ --- which is what the card mirroring the server made
# necessary and what one partition makes simple: the four files under the
# board's folder are binaries and carry no address, and a guard that stopped
# at the root would be reading one directory of four.
addrs=$(grep -rEoh \
		-e '([0-9]{1,3}\.){3}[0-9]{1,3}' \
		-e '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' \
		"$OUT/card/" 2>/dev/null \
		| grep -vxE '0\.0\.0\.0|127\.0\.0\.1|192\.0\.2\.[0-9]{1,3}|198\.51\.100\.[0-9]{1,3}|203\.0\.113\.[0-9]{1,3}' \
		| sort -u || true)
if [ -n "$addrs" ]; then
	echo "mksd-release: STOP --- something address-shaped is on the card:" >&2
	for a in $addrs; do
		grep -rEn -- "$a" "$OUT/card/" >&2 || true
	done
	exit 1
fi
echo "mksd-release: no address of any kind anywhere on the card --- no IP, no MAC"

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
for rc in "$OUT/card/fpgarc" "$OUT/card/muirrc"; do
	[ -f "$rc" ] || continue
	if grep -qE '^[[:space:]]*--chaos-udp-(default-)?peer' "$rc"; then
		echo "mksd-release: STOP --- $(basename "$rc") names a station off this board:" >&2
		grep -nE '^[[:space:]]*--chaos-udp-(default-)?peer' "$rc" >&2
		exit 1
	fi
done
echo "mksd-release: and no Chaosnet peer or bridge in either file of flags --- the network is the user's"

# **AND THE CARD SHIPS WITH NO BAND ON IT, WHICH IS A THIRD THING A FLAG
# CANNOT BE TRUSTED FOR.**  PACKS is refused above, SYS and SITE are refused
# above and STANDALONE clears CC_PACK, so three mechanisms already say no band
# ships; this reads the staged directory and says what is there.  A released
# card carrying somebody's Lisp world is the failure, and it would look exactly
# like a card that works.
#
# **IT IS A WHOLE-CARD LIST NOW AND IT USED TO BE THE PACK PARTITION'S.**  With
# two partitions this could say "README.TXT, fpgarc, muirrc and nothing else",
# because the loader's files were on the other one.  With one partition the
# same sentence has to name the loader's files too, so the list is built from
# what the staging script itself says the root may hold --- read out of it on
# its own anchor rather than written here a second time, because two lists of
# one thing part company on the first change.
ROOT_ALLOWED=$(sed -n 's/^.*case " \$ROOT_NAMES uEnv.txt README.TXT fpgarc muirrc " in$/ROOT/p' \
	boards/arty-z7-20/linux/mksd-buildroot.sh)
[ "$ROOT_ALLOWED" = ROOT ] || {
	echo "mksd-release: the staging script no longer says which names the root may hold: this guard has rotted" >&2
	exit 1; }
for f in "$OUT"/card/*; do
	[ -e "$f" ] || continue
	n=$(basename "$f")
	if [ -d "$f" ]; then
		case "$n" in
			"$BOARD_NAME") ;;
			# The three folders a release ships EMPTY.  They are on the
			# card so that somebody with it in a reader can see where a
			# band goes; a file in any of them is a band shipping.
			packs|sys|site)
				if [ -n "$(ls -A "$f")" ]; then
					echo "mksd-release: STOP --- $n/ is not empty; a release ships no band" >&2
					ls -A "$f" | sed 's/^/  /' >&2
					exit 1
				fi ;;
			*) echo "mksd-release: STOP --- the card carries the folder '$n/'" >&2; exit 1 ;;
		esac
		continue
	fi
	# WHICH FILES MAY BE AT THE ROOT IS NOT ASKED HERE, and that is
	# deliberate rather than an omission: mksd-buildroot.sh asserts the
	# root's whole name set against the loader's own fixed names for this
	# board, and it ran a moment ago as part of this release.  Asking again
	# would be a second list of one thing, which is a second place to be
	# wrong.  What is left for a RELEASE to say is the part that is about a
	# release and not about a card: that the three folders a band would go
	# in are empty, which is the loop above, and that the four files a card
	# cannot boot without are there, which is the loop below.
	:
done
for n in README.TXT fpgarc muirrc uEnv.txt; do
	[ -s "$OUT/card/$n" ] || { echo "mksd-release: STOP --- the card has no $n" >&2; exit 1; }
done
echo "mksd-release: the bay is empty and so are sys/ and site/ --- the band is the user's"

# **AND THE ZIP IS THE THING PUBLISHED, AND IT NAMES ITS BOARD.**  A release is
# one zip a board and the three differ in only a few files, so a file somebody
# downloaded a month ago has to say which board it is for without being opened.
# It says so three times: in its own name, in the README at the card's root,
# and in the folder the loader asks for by name --- which is the one of the
# three a machine acts on, and it is why a card made from the wrong board's zip
# stops at `Unable to read file <thisboard>/zImage` rather than doing something
# worse quietly.
#
# mksd-buildroot.sh has already unpacked this zip and compared it against the
# staged directory, so what is left here is to say where it is and how big.
ZIP="$OUT/cadr-$BOARD_NAME.zip"
[ -f "$ZIP" ] || { echo "mksd-release: no zip at $ZIP; mksd-buildroot.sh did not build one" >&2; exit 1; }
zs=$(stat -c %s "$ZIP")
unpacked=$(( $(du -s --block-size=1 "$OUT/card" | cut -f1) ))
echo "mksd-release: $ZIP  $zs bytes, $unpacked unpacked --- this is what is published for the $BOARD_NAME"
echo "mksd-release: sha256 $(sha256sum "$ZIP" | cut -d' ' -f1)"
echo "mksd-release: the user formats a microSD card as ONE FAT32 partition in an"
echo "mksd-release: MBR and unpacks this onto it.  Not exFAT, which no loader here"
echo "mksd-release: reads, and not a card with no partition table at all."
