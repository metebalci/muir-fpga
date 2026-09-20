#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Stage the card, and the TFTP server's directory, for the Buildroot image.
#
#     BIT=build/ddr/cadr_arty.bit boards/arty-z7-20/linux/mksd-buildroot.sh [PACKS="a.img 3=b.img"]
#
#     IMAGES=$HOME/.cache/muir-fpga-buildroot/out-de25/images \
#     BOARD_DIR=boards/de25-nano BOARD_DTB=socfpga_agilex5_de25_nano_cadr.dtb \
#     BIT=<the fabric's core.rbf> boards/arty-z7-20/linux/mksd-buildroot.sh
#
# The sibling of boards/arty-z7-20/linux/mksd.sh, which stages the stepping stone from
# Digilent's BSP and is left as it is.  This one takes what `make buildroot`
# built (output/images) and the bitstream it is told, and lays them out the
# way the board consumes them:
#
#     build/sd/buildroot/card/    BOOT.BIN u-boot.img uEnv.txt      -> partition 1
#     build/sd/buildroot/card/<board>/
#                                 cadr.bit zynq-arty-z7-20.dtb zImage
#                                 rootfs.cpio.uboot                --- the same partition
#     build/sd/buildroot/packs/   disk-pack-0.img .. disk-pack-7.img   -> partition 2
#     build/sd/buildroot/server/<board>/
#                                 uEnv.net cadr.bit zynq-arty-z7-20.dtb
#                                 zImage rootfs.cpio.uboot    -> /srv/tftp/<board>
#     build/sd/buildroot/sdcard.img                                   -> dd, instead of both
#
# THE SERVED SET IS UNDER A DIRECTORY NAMED FOR THE BOARD, and the name is
# the board's own directory under `boards/`.  One TFTP server serves more
# than one board here and every board's five files carry the same five names,
# so a flat server root would hand a Cora the Arty's bitstream --- a bitstream
# for the wrong part, which configures nothing and says nothing about why.
#
# **AND THE CARD MIRRORS THE SERVER.**  The same four files sit in a folder of
# the same name on the card's boot partition, and the board's U-Boot loads them
# from there.  A card belongs to one board, so the folder is not what keeps two
# boards' files apart on it; what it buys is that the card and the server hold
# the same thing in the same place, and that a file copied from one to the
# other keeps its path.  Three files stay at the ROOT of the partition because
# their names are not ours to move: BOOT.BIN, which the boot ROM reads from the
# root of the first FAT partition and nowhere else; u-boot.img, which the SPL
# asks for by that name at the root; and uEnv.txt, which U-Boot imports before
# any board name is known.  The pack partition keeps its flat layout, because a
# pack, a README and the two files of flags belong to the machine rather than
# to the part --- what differs between two boards' cards there is the Chaosnet
# address inside fpgarc and muirrc, which this script writes from each board's
# own local.conf.
#
# **DO NOT WRITE THE IMAGE WITH `conv=sparse`.**  It skips runs of zeros, so
# wherever the image holds zeros the card keeps whatever was there before.
# A disk pack is full of legitimate zeros.  Measured on 11 Sep: the image's
# md5 was right on the laptop, the card's `disk-pack-0.img` came out with a
# different one, and the card mounted and looked perfectly healthy.  Written
# again in full, it matched.  The flag is safe only on a blank card, which
# nobody can check, so it is never offered.
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
# it is.
#
# HOW BIG A CARD HAS TO BE.  BOOT_MB and PACKS_MB are the two partitions and
# both are parameters, because half a gigabyte of boot partition on a 1 GB
# card is most of the card.  The boot partition holds seven files and they
# come to about 11 MiB.  A T-300 pack is 257 MiB and a T-80 is 68.
#
#     card    BOOT_MB  PACKS_MB   the bay, and what is left over
#     1 GB         64       832   three drives
#     2 GB         64      1792   seven drives
#     4 GB         64      3584   all eight, and room for six spare packs
#
# Those are sized against what a card of that name really holds, which is
# less than the name: 1,003,520,000 bytes for a 1 GB card, 2,003,795,968 for
# a 2 GB and 3,965,190,144 for a 4 GB, with 16 MiB left spare on top of the
# partition table's own megabyte.  **An image larger than the card does not
# warn, it fails part way**: `dd` stops with "No space left on device", the
# boot partition is written because it comes first, and the pack partition
# is left truncated and claiming room the card has not got.
#
# **THE BAY IS EIGHT AND NO MORE**, because a drive is `disk-pack-<unit>.img`
# and a unit is 0 to 7.  Eight T-300 packs are 2,056 MiB.  Space past that
# holds packs under other names, which the bay ignores, so it is where
# backups and bands not currently mounted live.
#
# **BUT THE DEFAULT IS NOT A CARD, IT IS WHAT THE CARD CARRIES.**  BOOT_MB is
# 64 and PACKS_MB, unset, is what the packs named come to, plus the FAT's own
# 8 MiB, plus 32 MiB for the band's sources and plus 264 MiB for one more
# drive.  A card with an empty bay therefore comes out at 304 MiB of packs
# partition and one with a T-300 at 561, rather than at some round gigabyte,
# and either writes in about a minute.  Ask for a bigger partition when the
# card is bigger and the bay should be able to fill up without another write.
#
# **THE THREE TERMS ARE MEASURED AND NOT ESTIMATED.**  On a FAT32 image made
# by this card's own `mkfs.vfat -F 32`, the cluster is 4,096 bytes, a T-300
# pack takes 269,565,952 bytes, the sources this project ships beside take
# 17,031,168 (513 files in 25 directories), and a 320 MiB partition carrying
# both still reads back 48,250,880 bytes free.  A pack and its sources
# together need 274 MiB, so the 272 this used to default to was two megabytes
# short of the pair.
#
# So **1 GB is the absolute minimum** and one pack fits on far less than
# that, while **4 GB takes a full bay of eight**, which is 2,056 MiB of
# packs.  Nobody runs eight.  64 MiB of boot partition is decided and it is
# the default on every card: the seven files are 11.3 MiB, so it is six times
# what they need and leaves room for a second bitstream and a second kernel
# beside them.  The whole default image is 2,625 MiB.  A bigger card leaves
# the rest of itself unused, which costs nothing and is not worth a resize
# step at first boot; set PACKS_MB to the card you have if you want all of
# it, and remember that `dd` writes every byte of whatever size you ask for.
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
# WHICH BOARD, AND WHY IT IS TWO VARIABLES RATHER THAN A NAME.  This script
# stages a card for a board, and a second Zynq board is a second device tree
# and a second directory under `boards/` with everything else the same --- the
# partitions, the packs, the `fpgarc`, the `muirrc`, the U-Boot environment and
# every warning below are the machine's and not the part's.  So the board
# enters as the two things that differ: where its `linux/` directory is, and
# what its compiled device tree is called.  Both default to the Arty Z7-20's,
# so a run that sets neither is the run this script has always been.
#
#     BOARD_DIR=boards/cora-z7-07s BOARD_DTB=zynq-cora-z7-07s.dtb \
#         BIT=build/cora-ddr/cadr_cora.bit boards/arty-z7-20/linux/mksd-buildroot.sh
#
# `local.conf` is read out of `$BOARD_DIR/linux/`, so each board has its own
# server address, MAC and Chaosnet numbers --- which two boards on one network
# must, the development allocation reserving a second pair for exactly that.
BOARD_DIR=${BOARD_DIR:-boards/arty-z7-20}
BOARD_DTB=${BOARD_DTB:-zynq-arty-z7-20.dtb}
# The board's own name --- the last element of BOARD_DIR --- is also the name
# of its directory on the TFTP server, so the two cannot part company.
BOARD_NAME=$(basename "$BOARD_DIR")
BOARD=$BOARD_DIR/linux/buildroot/board/$BOARD_NAME
# **AND WHAT THE BOARD BOOTS, WHICH IS THE THIRD THING THAT DIFFERS.**  The two
# Zynq-7000 boards boot alike --- a boot ROM that reads BOOT.BIN, U-Boot in
# u-boot.img, the fabric as a .bit, a zImage --- and the DE25-Nano does not.
# Its first-stage loader lives in the QSPI flash and reads u-boot.itb, which is
# U-Boot and TF-A in one FIT; the fabric is a core.rbf that U-Boot hands to the
# Secure Device Manager; the kernel is an arm64 Image; the CADR's memory is
# reserved at 0xB000_0000; and the console and the debug window are on the
# lightweight bridge at 0x2000_0000.  Everything else below --- the
# partitions, the packs, the files of flags, every warning --- is the
# machine's and is the same on every board.  So the board enters here as the
# names and numbers that differ, every line below says them through these, and
# a board this does not name is a Zynq-7000 board, which is what every run
# before the DE25-Nano was.
#
#   ROOT_FILES   the files at the root of partition 1 besides uEnv.txt, each
#                as <its name in images/>:<its name on the card>
#   FABRIC       the fabric's file in the board's folder, and FABRIC_KIND
#                what it is, which decides how BIT is read
#   KERNEL       the kernel's file in the board's folder
#   LAST_STEP    the U-Boot environment's last step, which boots the kernel
#   DTS_DIR      where the board's tree is, under its board/ directory
#   RESERVED     the reserved-memory node the tree must carry, no-map
#   PL_NODE      a node the tree must NOT carry, if the board has one to name
#   *_WINDOW     the display's two windows and the debug window, which the
#                files of flags name; the programs have their own copy of
#                every address (cadr-common's cadr/cadr_board.h)
#   REBUILD      the Makefile target that rewrites a stale loader
#   FABRIC_FETCH which variable of the loader's environment fetches the
#                fabric's image.  The Zynq boards' `cadr_card` loads all four
#                files itself.  The DE25-Nano's does not: one of its two
#                arrangements may not configure its own fabric and must not so
#                much as ask for the image, so the fetch is a variable of its
#                own that `cadr_fabric` runs only on the path that loads.  The
#                checks below read the loader for the folder rule, and the
#                folder rule holds wherever the fetch lives.
case "$BOARD_NAME" in
  de25-nano)
    ROOT_FILES="u-boot.itb:u-boot.itb"
    FABRIC=cadr.core.rbf
    FABRIC_KIND=rbf
    FABRIC_FETCH=cadr_rbf_card
    FABRIC_FETCH_NET=cadr_rbf_net
    KERNEL=Image
    LAST_STEP=cadr_booti
    DTS_DIR=dts/intel
    RESERVED=cadr@b0000000
    PL_NODE=
    DISPLAY_WINDOW=0xB4000000
    COLOR_WINDOW=0xB4020000
    CONSOLE_WINDOW_US=0x2000_0000
    DEBUG_WINDOW=0x20001000
    DEBUG_WINDOW_US=0x2000_1000
    DEBUG_PORT="the lightweight HPS-to-FPGA bridge"
    REBUILD=buildroot-de25-rebuild
    ;;
  *)
    ROOT_FILES="boot.bin:BOOT.BIN u-boot.img:u-boot.img"
    FABRIC=cadr.bit
    FABRIC_KIND=bit
    FABRIC_FETCH=cadr_card
    FABRIC_FETCH_NET=
    KERNEL=zImage
    LAST_STEP=cadr_bootz
    DTS_DIR=dts/xilinx
    RESERVED=cadr@18000000
    PL_NODE=amba_pl
    DISPLAY_WINDOW=0x1C000000
    COLOR_WINDOW=0x1C020000
    CONSOLE_WINDOW_US=0x8000_0000
    DEBUG_WINDOW=0x80001000
    DEBUG_WINDOW_US=0x8000_1000
    DEBUG_PORT="M_AXI_GP1"
    REBUILD=buildroot-rebuild
    ;;
esac
# The FIT the first-stage loader reads, which carries U-Boot and its
# environment: the last of the root's files.
LOADER=${ROOT_FILES##*:}
# The board's four files, which the card's folder and the server's directory
# for the board both hold and the loader's environment names.
BOARD_FILES="$FABRIC $BOARD_DTB $KERNEL rootfs.cpio.uboot"
STAGED_FILES=$BOARD_FILES
BIT=${BIT:-}
PACKS=${PACKS:-}
# **THE BAND'S SOURCES, WHICH GO ON THE CARD BESIDE ITS PACK.**  SYS names a
# directory: the tree the board's own file and time host serves, staged as
# `sys/` on the packs partition and named on the card's menu as
# `--ozd-root sys=/mnt/packs/sys,ro`.  A pack and the sources that belong to it
# are one band, and they belong on one card together.
#
# It goes on the packs partition and not in the root filesystem, because that
# filesystem is a RAM disk unpacked at every boot: sixteen megabytes there is
# sixteen megabytes of every board's memory whether the files are ever asked
# for or not.  On this partition it costs memory to nobody, and it can be read
# and changed with the card in a reader, which is why the settings files are
# here too.
SYS=${SYS:-}
BOOT_MB=${BOOT_MB:-64}
PACKS_MB=${PACKS_MB:-}          # empty means "the packs, the sources, and one more drive"
STANDALONE=${STANDALONE:-}
# **RELEASE=1 IS ABOUT THE MENU AND STANDALONE=1 IS ABOUT WHAT IS PRIVATE**,
# and they are two flags because they are two properties.  STANDALONE says this
# card carries nothing out of local.conf, which is what keeps an address, a MAC
# and this board's own station numbers off a public artifact.  RELEASE says the
# card is the one a stranger is given, so the file of flags is written with the
# three lines a board out of the box needs live and every other flag present
# and commented out.  mksd-release.sh sets both; a card staged here for the
# card path sets STANDALONE alone and keeps the menu it has always had.
RELEASE=${RELEASE:-}
DTC=${DTC:-$HOSTBIN/dtc}

die() { echo "mksd-buildroot: $*" >&2; exit 1; }

ROOT_IMAGES=; ROOT_NAMES=
for rf in $ROOT_FILES; do
  ROOT_IMAGES="$ROOT_IMAGES ${rf%%:*}"; ROOT_NAMES="${ROOT_NAMES:+$ROOT_NAMES }${rf#*:}"
done
for f in $ROOT_IMAGES "$KERNEL" "$BOARD_DTB" rootfs.cpio.uboot; do
  [ -f "$IMAGES/$f" ] || die "no $f in $IMAGES: run 'make buildroot' first"
done
# **THE FABRIC MAY BE LEFT OUT, AND ONLY BY NAME.**  NO_FABRIC=1 stages a card
# whose board folder has no fabric file at all: the slot is there, named in
# the loader's environment and in the served uEnv.net, and empty.  It is for a
# board whose fabric does not exist yet --- the DE25-Nano's, today --- so that
# everything else on the card can be built and checked.  Such a card boots
# U-Boot and stops at the fabric's load, saying which file it could not read,
# every ten seconds, until the file is copied into the folder.  The one board
# it does not stop is a DE25-Nano whose uEnv.txt says the fabric was configured
# before U-Boot ran, which never asks for the file at all.  An empty BIT
# without NO_FABRIC=1 is still refused: the bitstream is named, never guessed.
NO_FABRIC=${NO_FABRIC:-}
if [ -n "$NO_FABRIC" ] && [ "$NO_FABRIC" != 0 ]; then
  [ -z "$BIT" ] || die "NO_FABRIC=1 and BIT=$BIT: name the fabric or leave it out, not both"
  STAGED_FILES="$BOARD_DTB $KERNEL rootfs.cpio.uboot"
else
  NO_FABRIC=
  [ -n "$BIT" ] || die "BIT is not set: name the bitstream, e.g. BIT=build/ddr/cadr_arty.bit $0, or NO_FABRIC=1 to stage the fabric's slot empty"
  [ -f "$BIT" ] || die "no bitstream at $BIT"
fi

# The address, the MAC, the Chaosnet peers and the debugger's pack, from the
# file the repository does not carry.  The first four are everything private a
# card can hold: an IP, a MAC and hosts on somebody's network.
# CHAOS_DEFAULT_PEER is one of them: it is the bridge, and a bridge is a
# machine on a real network like any other.  CC_PACK is private for a duller
# reason: it is a path on whoever's build host, and the file it names is
# 257 MiB and is not in the repository.
#
# **IT IS READ HERE, BEFORE THE BAY IS RESOLVED, AND IT USED TO BE READ TWO
# HUNDRED LINES LATER.**  As far as the card is concerned the debugger's pack
# is a pack: it takes a T-300's 257 MiB of partition 2, so it has to be known
# where the packs are sized and not where the files are written.  Read late,
# a card built with the default PACKS_MB would have squeezed it into the spare
# room meant for one more drive and left seven megabytes --- a card that
# stages without complaint and then has nowhere to put a band.
#
# **AND STANDALONE DOES NOT READ IT AT ALL**, which is the structural half of
# the paragraph below.  Clearing the values by name after sourcing the file
# works only for the names somebody remembered: local.conf can set any of the
# card's settings, because every one of them is read as `${VAR:-<default>}`,
# and only six were ever cleared.  Measured on this project's own development
# card: a release built here carried this board's own Chaosnet station number
# out of local.conf, because CHAOS_ADDR_FPGA was never in the list.  Not
# reading the file cannot go wrong that way, and it makes a release image
# depend on this script and on nothing on whoever's build host.
SERVERIP=; ETHADDR=; CHAOS_PEER=; CHAOS_DEFAULT_PEER=; CC_PACK=; NO_AUTO_BOOT=
NO_BLINKING_LEDS=; FABRIC_LOADED=
if [ -z "$STANDALONE" ] && [ -r "$BOARD_DIR/linux/local.conf" ]; then
  . "$BOARD_DIR/linux/local.conf"
fi
# **STANDALONE MEANS THE CARD CARRIES NOTHING FROM local.conf**, and that is
# wider than it used to be on purpose.  It cleared SERVERIP alone, which was
# right while the only private value on a card was the TFTP server's address.
# It is not any more: uEnv.txt carries ETHADDR, and both files of flags ---
# fpgarc for the CADR in the fabric and muirrc for the CADR inside muir ---
# carry CHAOS_PEER and CHAOS_DEFAULT_PEER, and a release card is built by
# setting exactly this flag.  Clearing one of the four and shipping the others
# is the failure this flag exists to prevent, so it clears all four and
# mksd-release.sh's guard is the check on it rather than the whole of it.
#
# **AND IT CLEARS CC_PACK TOO, FOR A DIFFERENT REASON.**  The debugger's pack
# carries no address and no host, so the release guard would never see it and
# nothing private would ship.  It is cleared because a release carries no band
# at all: mksd-release.sh refuses PACKS on the argument that a band is the
# user's own to supply, and the debugger's band is a band.  Left in, a
# released card would ship 257 MiB of somebody else's Lisp world and a muirrc
# naming a pack the user is free to delete.
#
# **AND IT CLEARS NO_AUTO_BOOT, which is not private and is cleared anyway.**
# A card somebody switches on has to boot its band; holding the machine at the
# button is what a board being worked on wants, and a released card that did
# it would look broken.  So it follows the flag rather than the rule about
# private values.
#
# **AND NO_BLINKING_LEDS, FOR THE SAME REASON.**  Steady lamps are what a board
# left running on a desk overnight wants, and a released card keeps the blink,
# which is what a stranger switching a board on for the first time can read.
#
# **AND IT CLEARS THE CHAOSNET STATION NUMBERS, WHICH IT USED NOT TO.**  Those
# two are not private in the way an address on somebody's network is --- the
# subnet is private in the way 192.168 is --- but they are this BOARD'S
# identity: the development allocation gives each board a pair, and a release
# carrying one of them is a card that joins that network as a machine that
# already exists.  Worse, it is a release that depends on who built it: the
# same command on another build host would publish that person's numbers.  The
# file is not read at all under this flag now, so what remains here is the
# environment, and an exported value has to be stopped the same way.
if [ -n "$STANDALONE" ]; then
  SERVERIP=; ETHADDR=; CHAOS_PEER=; CHAOS_DEFAULT_PEER=; CC_PACK=; NO_AUTO_BOOT=
  NO_BLINKING_LEDS=
  CHAOS_ADDR_FPGA=; CHAOS_ADDR_MUIR=; CHAOS_UDP_PORT=; CHAOS_UDP_PORT_MUIR=
  TERMINAL_ENDPOINT=; SERIAL_ENDPOINT=; KEYBOARD_BOOT=; MUIR_TERMINAL_PORT=
fi
if [ -n "${SERVERIP:-}" ]; then
  MODE="the network path: uEnv.txt names the TFTP server, the five files come from /srv/tftp/$BOARD_NAME"
else
  MODE="the card path: uEnv.txt names no server, the five files come from the card, no network is used"
fi
if [ -n "$STANDALONE" ]; then
  echo "mksd-buildroot: STANDALONE: no server, no MAC and no Chaosnet peers --- this card carries nothing from local.conf"
elif [ -z "${ETHADDR:-}" ]; then
  echo "mksd-buildroot: WARNING: no ETHADDR in $BOARD_DIR/linux/local.conf; the board will use a random MAC and U-Boot will say so" >&2
fi

# The drive bay, resolved before anything is written: which file goes on
# which unit, and whether they fit.  A pack is only a pack at exactly a
# T-300's or a T-80's size (boards/arty-z7-20/linux/buildroot/package/cadr-disk-packs/src/
# pack_bay.h), so a file of any other size is refused HERE rather than being
# staged and silently not being a drive on the board.
T300=269562880
T80=70937600

# **WHAT THE SOURCES TAKE ON THE CARD**, measured on the tree that is actually
# being staged rather than assumed.  `du` in 4,096-byte units is the cluster
# `mkfs.vfat` chooses for a partition of this size, so what is counted here is
# what the card will really spend: a file of one byte costs a whole cluster,
# and 513 small files is where that adds up.
sys_total=0
if [ -n "$SYS" ]; then
  [ -d "$SYS" ] || die "SYS names no directory at $SYS"
  sys_total=$(( $(du -s --block-size=4096 "$SYS" | cut -f1) * 4096 ))
  [ "$sys_total" -gt 0 ] || die "SYS at $SYS is empty; a card with an empty tree on it serves nothing"
fi

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

# **THE DEBUGGER'S PACK IS NOT ONE OF THE EIGHT.**  muir on this board's own
# Arm cores is the far end of the debug cable, and the debugger is not muir:
# it is CC running on a CADR that muir simulates.  So muir needs a band with
# CC already loaded in it, and that band rides on this partition beside the
# bay.  Its name must NOT be disk-pack-0.img to disk-pack-7.img, because those
# eight are the fabric machine's drive bay and this pack is muir's own; the
# card carries it as muir-cc.img and muirrc names it at that path
# (docs/cc-pack.md).
#
# Unset, muirrc keeps the two commented lines and their explanation, which is
# what every card built before the pack existed got.
#
# **EXACTLY A T-300, WHERE THE BAY ALSO TAKES A T-80.**  The bay takes both
# because the real controller had both geometries and muir has both; nothing
# this project makes is a T-80, and the band in this pack was saved into a
# T-300's partition table.  A T-80 here is a mistake and is refused as one.
CC_PACK_NAME=muir-cc.img
CC_PACK_SHA=
if [ -n "${CC_PACK:-}" ]; then
  [ -f "$CC_PACK" ] || die "CC_PACK names no file at $CC_PACK"
  size=$(stat -c %s "$CC_PACK")
  [ "$size" = "$T300" ] \
    || die "$CC_PACK is $size bytes, which is not a T-300 ($T300); every pack this project makes is a T-300 and the debugger's is not the exception"
  CC_PACK_SHA=$(sha256sum "$CC_PACK" | cut -d' ' -f1)
  packs_total=$((packs_total + size))
fi

# **THE THREE TERMS THE PACKS PARTITION IS MADE OF**, each a number with a
# reason, and all three measured on a FAT32 image made by the same
# `mkfs.vfat -F 32` this card is made with, with the real files copied in by
# `mcopy` and the free space read back afterwards.
#
#   THE FAT'S OWN ROOM.  A 320 MiB FAT32 keeps 696,320 bytes for its reserved
#   sectors and its two allocation tables, and that grows with the partition.
#   A megabyte a pack and eight besides is generous and stays generous.
PACKS_FAT_MB=8
#   ROOM FOR ONE MORE DRIVE.  A T-300 is 257 MiB, so 264 is enough to copy a
#   pack in beside what is already there.  `dd` writes every byte of the
#   image, so a partition sized for nine drives costs eight drives' worth of
#   zeros on a card carrying one.
PACKS_SPARE_MB=264
#   ROOM FOR THE BAND'S SOURCES.  The board serves its own files now, and what
#   it serves lives on this partition rather than in the root filesystem,
#   which is a RAM disk unpacked at every boot: a tree there would be sixteen
#   megabytes of every board's memory whether anybody ever asked for a file or
#   not.  The tree this project ships beside is 513 files in 25 directories and
#   takes 17,031,168 bytes on this filesystem --- 16.24 MiB, at the 4,096-byte
#   cluster `mkfs.vfat` chooses for a partition of this size.  This is double
#   that, so the tree may grow by 97% before the card has to be laid out
#   again, and it is set aside whether or not a tree is staged today, exactly
#   as the drive above is.
PACKS_SYS_MB=32

# **THE SIZE ITSELF, AS ONE FUNCTION, SO THAT A CHECK CAN RUN IT.**  $1 is the
# bytes of every pack named and $2 the bytes the staged tree takes on the card.
# A staged tree larger than the room set aside for one takes the room it needs
# instead, rounded up to the megabyte: a card that carries a tree must hold it,
# and a reserve that a real tree overflowed would be a card that failed at the
# last file copied.
packs_partition_mb() {
	_sys=$(( $2 / 1048576 + 1 ))
	[ "$_sys" -lt "$PACKS_SYS_MB" ] && _sys=$PACKS_SYS_MB
	echo $(( $1 / 1048576 + _sys + PACKS_FAT_MB + PACKS_SPARE_MB ))
}

packs_need=$(( packs_total / 1048576 + PACKS_FAT_MB + sys_total / 1048576 + 1 ))
# THE DEFAULT IS WHAT IS BEING CARRIED PLUS ROOM FOR ONE MORE DRIVE, not a
# round number.  `dd` writes every byte of the image, so a partition sized for
# nine drives costs eight drives' worth of zeros on a card carrying one.  A
# T-300 is 257 MiB, so the spare room is 264: enough to copy a pack in beside
# what is there, and enough on its own for an empty bay.  The debugger's pack
# counts as carried, not as spare: a card with a bay pack and a CC pack comes
# out at 851 MiB and still has room for one more drive.  Ask for more with
# PACKS_MB and the table in this header says what each card takes.
[ -n "$PACKS_MB" ] || PACKS_MB=$(packs_partition_mb "$packs_total" "$sys_total")
[ "$PACKS_MB" -ge "$packs_need" ] \
  || die "PACKS_MB=$PACKS_MB is too small for the packs named ($packs_need MiB needed)"
[ "$PACKS_MB" -ge 64 ] || die "PACKS_MB=$PACKS_MB: the pack partition is not worth making smaller than 64 MiB"
# The boot partition holds seven files and they come to about 11 MiB, so 32 MiB
# is a floor with room for a second bitstream rather than a tight fit.  It is a
# parameter because half a gigabyte of it on a 1 GB card is most of the card.
[ "$BOOT_MB" -ge 32 ] || die "BOOT_MB=$BOOT_MB: the boot partition holds about 11 MiB of files and 32 MiB is the floor"

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

# This script reads no header out of a core.rbf, so what goes in the log for
# one is its size and its digest, which identify the file if not its
# provenance.
if [ -n "$NO_FABRIC" ]; then
  echo "mksd-buildroot: THE FABRIC'S SLOT IS EMPTY (NO_FABRIC=1): $BOARD_NAME/$FABRIC is on neither the card nor the"
  echo "mksd-buildroot:   server, and the loader will stop at it, saying so, until it is copied there ---"
  echo "mksd-buildroot:   unless the card says the fabric was configured before U-Boot ran, which never asks for it"
elif [ "$FABRIC_KIND" = rbf ]; then
  echo "mksd-buildroot: the fabric $BIT"
  echo "mksd-buildroot:   $(stat -c %s "$BIT") bytes, sha256 $(sha256sum "$BIT" | cut -d' ' -f1)"
else
  BITLINE=$(bitinfo "$BIT") || die "$BIT does not carry a Xilinx bitstream header"
  echo "mksd-buildroot: bitstream $BIT"
  echo "mksd-buildroot:   $BITLINE"
fi

rm -rf "$OUT"
mkdir -p "$OUT/card/$BOARD_NAME" "$OUT/packs" "$OUT/server/$BOARD_NAME"

# The card: everything.  Three files at the root, because their names are not
# ours to move --- the boot ROM reads BOOT.BIN from the root of the first FAT
# partition and nowhere else, the SPL asks for u-boot.img by that name at the
# root, and U-Boot imports uEnv.txt before it could know a board name.  The
# board's own four go in the folder named for it, exactly as they sit in the
# server's directory for it.
for spec in $ROOT_FILES; do
  cp "$IMAGES/${spec%%:*}" "$OUT/card/${spec#*:}"
done
[ -n "$NO_FABRIC" ] || cp "$BIT" "$OUT/card/$BOARD_NAME/$FABRIC"
cp "$IMAGES/$BOARD_DTB" "$IMAGES/$KERNEL" "$IMAGES/rootfs.cpio.uboot" "$OUT/card/$BOARD_NAME/"
sed -e "s/@SERVERIP@/${SERVERIP:-}/" -e "s/@ETHADDR@/${ETHADDR:-}/" \
    -e '/^serverip=$/d' -e '/^ethaddr=$/d' "$BOARD/uEnv.txt.in" > "$OUT/card/uEnv.txt"
grep -q '@' "$OUT/card/uEnv.txt" && die "uEnv.txt still carries a marker"

# **AND WHETHER THE CARD SAYS THE FABRIC WAS CONFIGURED BEFORE U-BOOT RAN.**
# A board whose first stage is not in its flash yet is configured over JTAG
# from one file that also starts the processor, so its fabric is already in
# place when U-Boot runs and the processor may not configure it a second time
# (Technical Reference Manual, the Secure Device Manager's configuration
# order).  The template carries `cadr_fabric_loaded=1` commented out under the
# sentence that explains it, exactly as the file of flags carries the boot
# button's line, and FABRIC_LOADED=1 in local.conf is what makes it live.  It
# belongs beside the board's other settings because it is a fact about how
# THIS board is started and not about the design: the same card, on the day
# the flash is written, wants the line commented again, which is one character
# with the card in a reader.
#
# **AND IT IS WHAT LETS A CARD WITH AN EMPTY FABRIC SLOT BOOT.**  The image is
# fetched inside the branch that loads it, so a board told the fabric is
# already there never asks for the file and never stops at it.  STANDALONE
# clears the variable with everything else local.conf sets, so a released card
# always loads its own fabric.
if [ -n "${FABRIC_LOADED:-}" ] && [ "$FABRIC_LOADED" != 0 ]; then
  grep -qx '#cadr_fabric_loaded=1' "$OUT/card/uEnv.txt" \
    || die "FABRIC_LOADED=1, and $BOARD/uEnv.txt.in carries no '#cadr_fabric_loaded=1' line to make live: this board's loader has no such setting"
  sed -i 's/^#cadr_fabric_loaded=1$/cadr_fabric_loaded=1/' "$OUT/card/uEnv.txt"
  grep -qx 'cadr_fabric_loaded=1' "$OUT/card/uEnv.txt" \
    || die "uEnv.txt still does not say the fabric was configured before U-Boot ran"
  echo "mksd-buildroot: uEnv.txt says the fabric was configured before U-Boot ran (FABRIC_LOADED=1):"
  echo "mksd-buildroot:   the loader opens its bridges and never reads $BOARD_NAME/$FABRIC"
fi  # whether the card says the fabric was configured before U-Boot ran

# The drive bay: nothing but packs, named by unit.  A hard link where the
# filesystem allows one, so that staging a 270 MB pack is not a copy.
for spec in $pack_files; do
  unit=${spec%%=*}; file=${spec#*=}
  cp -l "$file" "$OUT/packs/disk-pack-$unit.img" 2>/dev/null \
    || cp "$file" "$OUT/packs/disk-pack-$unit.img"
done

# The debugger's pack, beside the bay and not in it.  Hard linked like the
# others where the filesystem allows one, and then digested --- which says
# which of the two happened and that the bytes staged are the bytes CC_PACK
# named.  A link makes the staged name resolve to that very file; a copy makes
# it a copy of it.  What proves the IMAGE holds those bytes is the mtools
# readback further down, which compares every file on partition 2 against this
# directory byte for byte.
#
# **NOTHING HERE IS `dd conv=sparse`, and a pack is why.**  That flag skips
# runs of zeros, and a disk pack is full of legitimate zeros, so wherever the
# image has them a card keeps whatever it held before.  Measured on this
# project's own card: the image's digest was right and the card's pack read
# back different.  `cp` writes every byte.
if [ -n "${CC_PACK:-}" ]; then
  cp -l "$CC_PACK" "$OUT/packs/$CC_PACK_NAME" 2>/dev/null \
    || cp "$CC_PACK" "$OUT/packs/$CC_PACK_NAME"
  staged=$(sha256sum "$OUT/packs/$CC_PACK_NAME" | cut -d' ' -f1)
  [ "$staged" = "$CC_PACK_SHA" ] \
    || die "packs/$CC_PACK_NAME staged as $staged where $CC_PACK is $CC_PACK_SHA"
  if [ "$(stat -c %d:%i "$CC_PACK")" = "$(stat -c %d:%i "$OUT/packs/$CC_PACK_NAME")" ]
  then how="hard linked"; else how=copied; fi
  echo "mksd-buildroot: the debugger's pack: $CC_PACK $how to packs/$CC_PACK_NAME"
  echo "mksd-buildroot:   $CC_PACK_SHA"
fi

# **AND THE BAND'S SOURCES, IF A TREE WAS NAMED.**  A pack is a band and this
# is the band's files; the two belong on one card together, because a board
# that serves itself its own files has to have them.  `cp -a` keeps the modes
# and the times, and the count staged is asserted against the count named, so
# a copy that came out short is a failure here rather than a file the machine
# asks for and does not get.
if [ -n "$SYS" ]; then
  rm -rf "$OUT/packs/sys"
  cp -a "$SYS" "$OUT/packs/sys"
  want=$(find "$SYS" -type f | wc -l)
  got=$(find "$OUT/packs/sys" -type f | wc -l)
  [ "$want" = "$got" ] \
    || die "the sources staged as $got files where $SYS has $want"
  echo "mksd-buildroot: the band's sources: $SYS -> packs/sys, $got files," \
       "$sys_total bytes on the card"
fi

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
  printf 'This partition holds the disk packs, and the few settings files that\r\n'
  printf 'have to survive a reboot.  Everything else on the board runs from a\r\n'
  printf 'RAM disk unpacked at every boot, so a file edited there is lost; a\r\n'
  printf 'file edited here is not.  The settings files are fpgarc and muirrc,\r\n'
  printf 'one for each of the two CADRs this board runs: fpgarc configures the\r\n'
  printf 'machine in the fabric and muirrc the machine inside muir, which is\r\n'
  printf 'the debugger.  Both are lists of flags, one a line, and each says at\r\n'
  printf 'its top what it is for.\r\n\r\n'
  printf 'Name a pack\r\n'
  printf 'disk-pack-0.img to disk-pack-7.img: the number is the disk unit the\r\n'
  printf 'machine sees it on, and whichever of the eight files exist are the\r\n'
  printf 'drives that are present.  A pack must be exactly 269,562,880 bytes\r\n'
  printf '(a T-300) or 70,937,600 (a T-80); any other size is not a pack.\r\n\r\n'
  printf 'muir-cc.img, if this card carries it, is not one of the eight and is\r\n'
  printf 'not a drive.  It is the debugger pack: a band with CC already loaded\r\n'
  printf 'in it, which muir reads and the machine in the fabric never sees.\r\n'
  printf 'muirrc is what names it, and the two are deleted or kept together.\r\n\r\n'
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

# ------------------------------------------------- the fabric CADR's flags
#
# **ONE FILE A STATION, IN muir'S OWN rc FORMAT.**  `fpgarc` configures the
# CADR in the fabric and `muirrc` beside it configures the CADR inside muir,
# so the two machines on this board are configured the same way with the same
# flag names.  One flag a line, the flag then a space then the rest of the
# line as its argument, `#` a comment, CRLF because the reader is Notepad.
#
# It replaced three files of one value each --- an address, a port and a list
# of peers --- and the reason is worth keeping: each was read by a little
# shell in the init script, one of those readers stripped a carriage return
# and the other did not, and every peer reached the program with a `\r` on
# the end of its port.  A file of flags has no values for a shell to get
# wrong, and it is the same file the program would have been given on a
# command line.
#
# **THE NUMBERS ARE THE SAME ON EVERY CARD, RELEASE INCLUDED**: the port
# numbers and the addresses alike, since it is a private subnet.  Subnet
# 0o376 is private in the way 192.168 is, so two boards out of the box do not
# collide with anybody.
# **ONLY THE PEERS ARE PRIVATE**, because they name real hosts on a real
# network: they come from `local.conf`, the same rule and the same file as
# SERVERIP, and a card built without them gets a file that says what to put
# in it.
CHAOS_ADDR=${CHAOS_ADDR_FPGA:-177101}
CHAOS_PORT=${CHAOS_UDP_PORT:-42042}
# The two endpoints written out in full rather than left to the programs'
# defaults, so that the card SAYS where the screen and the line are.  They are
# the same numbers the init scripts pass, and a card that says nothing gets
# them anyway; saying them is what lets somebody at a card reader change one.
TERMINAL_ENDPOINT=${TERMINAL_ENDPOINT:-0.0.0.0:5900}
SERIAL_ENDPOINT=${SERIAL_ENDPOINT:-0.0.0.0:7641}
KEYBOARD_BOOT=${KEYBOARD_BOOT:-ctrl,meta}

# **A RELEASE CARD'S MENU HAS THREE LIVE LINES, AND THE DEVELOPMENT CARD'S IS
# THE SAME MENU WITH MORE OF THEM LIVE.**  The file is the whole menu on both:
# every flag every program takes is in it, each under the sentence that says
# what it does.  What differs is which of them are live, and on a release that
# is the three a board out of the box needs and nothing else --- the address
# switches, the screen, and the chord that boots the machine.
#
#     --chaos-address     a Chaosnet interface HAS an address whether or not
#                         anything is plugged into it, so the switches are
#                         always set.  A band calls the machine by the number
#                         its own host table gives, so this is the line a user
#                         changes to suit the band they put in the bay.
#     --terminal          the screen, which is the only way to use a board
#                         that has no monitor of its own plugged in.
#     --keyboard-boot     the chord that cold-boots the machine, which
#                         somebody at a viewer needs on the first boot.
#
# **AND THE TWO THAT COME OUT ARE THE CABLE AND THE SERIAL LINE.**  Both are
# things a user plugs in rather than settings a card can guess at.  A release
# with the cable live would put a station on a network the user has not got,
# listening on a port nobody named, and the peer lines that would make it
# reach anything are the user's own to write.  A release with the serial line
# live would offer an unauthenticated port on every interface for a cable
# hardly anybody wants.  muir's own rule for both is that they are off unless
# asked for, and this follows it.
#
# Each is one `#` away from being on, with the sentence explaining it on both
# cards.  The init scripts follow the same rule from the other side: a file
# that is present and says nothing about the cable is a cable not plugged in,
# and one that says nothing about `--serial` is a serial line that is off.
#
# **AND THE JA RIBBON'S WIRING IS LIVE ON A DEVELOPMENT CARD AND COMMENTED ON
# A RELEASE, THOUGH BOTH SAY THE SAME THING.**  `auto` is the fabric's own
# reset value, so the line changes nothing either way; what it buys on a card
# that is being worked on is that the boot log says which wiring the board is
# on, and that the path from the card to the console is exercised at every
# boot rather than only when somebody is diagnosing a cable.  A release keeps
# its three live lines.
#
# **THE CABLE CAME BACK ONTO THE RELEASED MENU WHEN THE BOARD GAINED A FILE
# HOST OF ITS OWN, AND IT CAME BACK ON THE LOOPBACK.**  The argument for
# leaving it out was that a release with the cable live would put a station on
# a network the user has not got, listening on a port nobody named, with no
# peer it could reach.  Two of those three are still true of a cable on every
# interface and none of them is true of a cable on the loopback: nothing
# listens on any network, and there IS a peer it can reach, which is the file
# and time host S84ozd starts on the board.  A board out of the box is a whole
# site, which is the whole point of putting that host there, and it cannot be
# one with its cable unplugged.  A user who wants a station on their own
# network changes 127.0.0.1 to 0.0.0.0 in that one line.
# **AND THE HOST ON THE BOARD IS TURNED OFF EXACTLY WHEN THE CARD NAMES ONE ON
# A NETWORK.**  A band calls ONE address for its file host.  A card with peer
# lines has been told where that host is, and a second host answering at the
# same address on the loopback would be one Chaos address at two endpoints,
# which the Chaosnet program refuses by name --- leaving the board with no
# cable at all.  So a card that names a peer writes `--no-ozd` live, and every
# other card writes it commented out under the sentence that explains it.  The
# peers come from local.conf, so a release card, which has none, keeps its own
# host; the cards this project builds for its own boards name the host that
# runs beside them and turn theirs off.
if [ -n "${CHAOS_PEER:-}" ]; then
  MENU_NO_OZD=""
else
  MENU_NO_OZD="#"
fi
# **AND THE TREE IS NAMED ON THE MENU WHEN THERE IS ONE ON THE CARD.**  A line
# naming a tree that is not there stops the host, in its own words, so the line
# is live exactly when the tree was staged.  It is read-only, which is what a
# tree of sources wants and what keeps anything that reaches the host's socket
# from writing in it.
if [ -n "${SYS:-}" ]; then
  MENU_OZD_ROOT=""
else
  MENU_OZD_ROOT="#"
fi
CABLE_ENDPOINT=0.0.0.0:$CHAOS_PORT
if [ -n "${RELEASE:-}" ]; then
  CABLE_ENDPOINT=127.0.0.1:$CHAOS_PORT
  MENU_CABLE=""
  MENU_SERIAL="#"
  MENU_WIRING="#"
else
  MENU_CABLE=""
  MENU_SERIAL=""
  MENU_WIRING=""
fi
# **THE BOOT BUTTON IS A COMMENT UNLESS local.conf ASKS FOR IT.**  A card that
# boots its band by itself is what somebody switching a board on wants, so the
# line is written commented out with the sentence that explains it, and a
# board that is being worked on sets NO_AUTO_BOOT=1 in local.conf and gets the
# same line live.  The prefix is the whole difference, so the two cards differ
# in one character and the explanation is on both.
if [ -n "${NO_AUTO_BOOT:-}" ] && [ "${NO_AUTO_BOOT}" != "0" ]; then
  NO_AUTO_BOOT_PREFIX=""
else
  NO_AUTO_BOOT_PREFIX="#"
fi
# **THE LAMPS BLINK UNLESS local.conf ASKS FOR A LEVEL, AND A RELEASE ALWAYS
# BLINKS.**  The same one-character difference as the boot button's: a board
# that is being worked on and left running sets NO_BLINKING_LEDS=1 in
# local.conf and gets `--no-blinking-leds` live, and every other card carries
# the same line commented out under the same sentence.  A released card is
# written commented whatever the environment says --- STANDALONE has already
# cleared the variable, and RELEASE is asked here as well, so that the menu a
# stranger is given never depends on one flag having done its job.
if [ -n "${NO_BLINKING_LEDS:-}" ] && [ "${NO_BLINKING_LEDS}" != "0" ] \
   && [ -z "${RELEASE:-}" ]; then
  NO_BLINKING_LEDS_PREFIX=""
else
  NO_BLINKING_LEDS_PREFIX="#"
fi
# **EVERY FLAG EVERY PROGRAM TAKES FROM THIS FILE IS WRITTEN INTO IT, grouped
# by program, each under a sentence or two saying what it does and what it
# falls back to.**  The ones a card uses are live and the rest are commented
# out, so that somebody with the card in a reader sees the whole menu and
# uncomments what they want instead of going to look for a list somewhere
# else.  `fpgarc.pass` holds the two together: every flag named in any init
# script's own list must appear here exactly once, so a flag added to a
# program and not to this file fails the check by name.
#
# **THE CONVENTION THAT MAKES THAT CHECKABLE**: a commented-out SETTING is `#`
# with the flag immediately after it and no space, and a flag written inside
# prose is indented away from the `#`.  So `#--bow` is a setting somebody may
# uncomment and `#     --chaos-udp-peer <address>@<host>:<port>` is a sentence
# about one.  The reader treats both as comments; only the check tells them
# apart, and it is what keeps the menu honest.
{
  printf "# The flags for the CADR in the fabric, so that its programs are\r\n"
  printf "# configured the way muir is: one flag a line, the flag then a space\r\n"
  printf "# then the rest of the line as its argument, and a line that is blank\r\n"
  printf "# or starts with # is a comment.  muirrc beside this file is the same\r\n"
  printf "# format for the CADR inside muir.\r\n"
  printf "#\r\n"
  printf "# Several programs serve this machine and each takes the flags that\r\n"
  printf "# are its own out of this file: the screen, the serial line, the\r\n"
  printf "# network, the USB input and the boot button.  A flag names one of\r\n"
  printf "# them, and a flag none of them owns goes to nobody.  docs/fpgarc.md\r\n"
  printf "# lists what each one takes.\r\n"
  printf "#\r\n"
  printf "# EVERY flag those programs take is below, grouped by program.  The\r\n"
  printf "# ones this card uses are live; the rest are commented out with what\r\n"
  printf "# they do, to be uncommented.  A flag given twice is settled by the\r\n"
  printf "# program, which takes the last one.\r\n"

  printf "\r\n"
  printf "# ======================================================= the network\r\n"
  printf "# Read by the Chaosnet program. docs/chaosnet.md says what each means.\r\n"
  printf "\r\n"
  printf "# The sixteen address switches on the Chaosnet card: this machine's\r\n"
  printf "# own address, in octal.  Not a preference --- it is what the\r\n"
  printf "# hardware IS, and it is set whether or not the cable below is\r\n"
  printf "# plugged in.  A band calls the host ITS OWN table names, so a band\r\n"
  printf "# other than the one this card ships with may want another number.\r\n"
  printf -- "--chaos-address %s\r\n" "$CHAOS_ADDR"
  printf "\r\n"
  printf "# The cable: Chaosnet over UDP.  THIS LINE IS THE CABLE PLUGGED IN, and\r\n"
  printf "# without it nothing is sent and the peer lines below are refused ---\r\n"
  printf "# the address switches are one flag and the cable is another, as they\r\n"
  printf "# are two things on the board.  A machine with the switches set and\r\n"
  printf "# no cable is a machine on no network, which is what a board out of\r\n"
  printf "# the box is until somebody says otherwise.  42042 is the protocol's\r\n"
  printf "# own port and the CADR in fabric takes it; the CADR inside muir\r\n"
  printf "# takes another in muirrc, two stations on one port being a collision\r\n"
  printf "# rather than a network.\r\n"
  printf "# A released card names the loopback, because the host this machine\r\n"
  printf "# calls for its files and its time is on this board: the cable is\r\n"
  printf "# plugged into the board itself and into no network.  0.0.0.0 here\r\n"
  printf "# instead puts the machine on every interface, which is what a card\r\n"
  printf "# that is being worked on wants and what a user who has a file host\r\n"
  printf "# of their own on a network wants.\r\n"
  printf -- "%s--chaos-udp %s\r\n" "$MENU_CABLE" "$CABLE_ENDPOINT"
  printf "\r\n"
  printf "# The other stations, one a line, in muir's own syntax:\r\n"
  printf "#\r\n"
  printf "#     --chaos-udp-peer <chaosnet address>@<host or IP>:<port>\r\n"
  printf "#\r\n"
  printf "# The host your band calls goes here.  That host is ON THE NET and\r\n"
  printf "# not inside any of these programs, so a machine with no peers says\r\n"
  printf "# its file host is not answering --- which is true.  The port may be\r\n"
  printf "# left off for 42042.  Repeatable, once for each station.\r\n"
  if [ -n "${CHAOS_PEER:-}" ]; then
    for peer in ${CHAOS_PEER}; do printf -- "--chaos-udp-peer %s\r\n" "$peer"; done
  else
    printf -- "#--chaos-udp-peer 3060@192.0.2.1:42043\r\n"
  fi
  printf "\r\n"
  printf "# The way out, if there is one.  A frame whose destination no peer\r\n"
  printf "# line above names goes there rather than nowhere, which is what lets\r\n"
  printf "# a bridge carry this machine's traffic on to the wider Chaosnet.\r\n"
  printf "# Naming that bridge as a peer does not do it: a peer line places ONE\r\n"
  printf "# address.  So this takes an endpoint and no Chaosnet address, the\r\n"
  printf "# frame carrying the real destination for the bridge to route on.  A\r\n"
  printf "# broadcast is not sent here; it goes to the peers above, who are\r\n"
  printf "# stations on this machine's own cable.  Off by default, and a frame\r\n"
  printf "# no peer line names is dropped.\r\n"
  if [ -n "${CHAOS_DEFAULT_PEER:-}" ]; then
    printf -- "--chaos-udp-default-peer %s\r\n" "$CHAOS_DEFAULT_PEER"
  else
    printf -- "#--chaos-udp-default-peer 192.0.2.1:42042\r\n"
  fi
  printf "\r\n"
  printf "# Every Chaosnet packet and frame on the cable, to the log.  Off by\r\n"
  printf "# default: it is a great deal of output and it is for finding out why\r\n"
  printf "# a host is not answering.\r\n"
  printf -- "#--chaos-trace\r\n"

  printf "\r\n"
  printf "# ====================== the file and time host on this board (ozd)\r\n"
  printf "# Read by the host's own init script, which starts it before the\r\n"
  printf "# Chaosnet.  A CADR has no file or time server in it and neither has\r\n"
  printf "# the program above; the host a band calls is a machine on the\r\n"
  printf "# network, and this is one on the board.  It is ON, and it listens on\r\n"
  printf "# the loopback, so nothing off this board can reach it.\r\n"
  printf "# docs/chaosnet.md says what it serves and where its files go.\r\n"
  printf "\r\n"
  printf "# Do not run it at all.  Use this when the band's file host is a real\r\n"
  printf "# machine on your network: the two would answer at one Chaosnet\r\n"
  printf "# address, and one address placed twice stops the Chaosnet program.\r\n"
  printf -- "%s--no-ozd\r\n" "$MENU_NO_OZD"
  printf "\r\n"
  printf "# The Chaosnet address it answers at, in octal.  THIS IS NOT FREE TO\r\n"
  printf "# CHOOSE: a band calls its file and time host at the address its own\r\n"
  printf "# host table gives, and a host answering anywhere else is a host the\r\n"
  printf "# band never calls.  The default is 177200.  System 100 calls 3060\r\n"
  printf "# and System 304 calls 4403.\r\n"
  printf -- "#--ozd-chaos-address 177200\r\n"
  printf "\r\n"
  printf "# Its names, as a band's host table writes them: the official name\r\n"
  printf "# first, then the system type.  The default is OZ,system=UNIX.\r\n"
  printf -- "#--ozd-name OZ,system=UNIX\r\n"
  printf "\r\n"
  printf "# The loopback port it listens on.  42042 is the machine's own and\r\n"
  printf "# 42043 is muir's, so this is a third; the default is 42142.\r\n"
  printf -- "#--ozd-port 42142\r\n"
  printf "\r\n"
  printf "# A tree it serves, mounted at /<name>.  Repeatable.  Nothing is\r\n"
  printf "# served by default and that costs no memory, which is the point:\r\n"
  printf "# the host is on for every board and a tree in the root filesystem\r\n"
  printf "# would be about 16 MiB of every board's memory whether anybody asked\r\n"
  printf "# for a file or not.  Put the band's sources on THIS partition and\r\n"
  printf "# name them here, and they cost memory to nobody:\r\n"
  printf "#\r\n"
  printf "#     --ozd-root sys=/mnt/packs/sys,ro\r\n"
  printf "#\r\n"
  printf "# ,ro is read-only, which is what a tree of sources wants.  Without\r\n"
  printf "# it the host may write in the tree, and anything that reaches its\r\n"
  printf "# socket may.  The user's own directory is always there and is always\r\n"
  printf "# in memory, so a band that compiles a system has somewhere to put\r\n"
  printf "# its warnings without a line here.\r\n"
  printf -- "%s--ozd-root sys=/mnt/packs/sys,ro\r\n" "$MENU_OZD_ROOT"
  printf "\r\n"
  printf "# A machine in the host table it answers HOSTAB from, so that a band\r\n"
  printf "# whose own table does not know a name can still find it.\r\n"
  printf "# Repeatable, once a machine.  This board's own is the first one to\r\n"
  printf "# put here, at the address the switches above are set to.\r\n"
  printf -- "#--ozd-host %s,LISPM-1,system=LISPM\r\n" "$CHAOS_ADDR"
  printf "\r\n"
  printf "# A band's own host table file, whose hosts are answered for as well.\r\n"
  printf "# A site that already keeps that file writes each host once instead\r\n"
  printf "# of twice.  It is read when the host starts.\r\n"
  printf -- "#--ozd-hosts-text /mnt/packs/sys/site/hosts.text\r\n"
  printf "\r\n"
  printf "# Every packet it sees, to its log.  Off by default: the log is in\r\n"
  printf "# memory and this is a great deal of output.\r\n"
  printf -- "#--ozd-trace\r\n"

  printf "\r\n"
  printf "# ======================================================== the screen\r\n"
  printf "# Read by the terminal program, which serves the display, keyboard\r\n"
  printf "# and mouse over RFB. docs/terminal.md says what each means.\r\n"
  printf "\r\n"
  printf "# Where the screen is served: nothing, a port, an address, or\r\n"
  printf "# address:port, which is muir's own grammar for its own --terminal.\r\n"
  printf "# Every interface, so that a VNC viewer on another machine can reach\r\n"
  printf "# it; 127.0.0.1:5900 keeps it to this board and an SSH tunnel.  RFB's\r\n"
  printf "# None security is the only type offered and a viewer needs no\r\n"
  printf "# password.  5900 is what a viewer calls display :0.\r\n"
  printf -- "--terminal %s\r\n" "$TERMINAL_ENDPOINT"
  printf "\r\n"
  printf "# What a viewer's keysyms mean on the Lisp Machine keyboard: muir's\r\n"
  printf "# own \`key\` and \`prefix\` lines, over the built-in mapping rather than\r\n"
  printf "# replacing it.  \`muir --keyboard-mapping-dump\` writes a file to edit.\r\n"
  printf "# terminal.keyboard.mapping.txt beside this file is taken with no\r\n"
  printf "# line here at all; this names another.\r\n"
  printf -- "#--keyboard-mapping /mnt/packs/terminal.keyboard.mapping.txt\r\n"
  printf "\r\n"
  printf "# The keys the keyboard's boot sequence needs: held with Rubout they\r\n"
  printf "# cold-boot the machine and with Return they warm-boot it, as on a\r\n"
  printf "# CADR.  ctrl,meta is either Control and either Meta, which is\r\n"
  printf "# Ctrl-Alt-Del on any keyboard; ctrl,ctrl,meta,meta is both of each,\r\n"
  printf "# the CADR keyboard's own sequence.\r\n"
  printf -- "--keyboard-boot %s\r\n" "$KEYBOARD_BOOT"
  printf "\r\n"
  printf "# Say when a key going up is held back behind a boot word.  Off by\r\n"
  printf "# default; it is for finding out why a chord did not boot.\r\n"
  printf -- "#--keyboard-boot-trace\r\n"
  printf "\r\n"
  printf "# The display's MODE BOW: one bits are black.  Off by default, which\r\n"
  printf "# is the fabric's own power-on state and muir's --- a one bit white.\r\n"
  printf -- "#--bow\r\n"
  printf "\r\n"
  printf "# The display's region in memory, and how often it is read while\r\n"
  printf "# anybody is watching, in milliseconds.  The defaults are where the\r\n"
  printf "# fabric puts the window and about sixty frames a second.\r\n"
  printf -- "#--window %s\r\n" "$DISPLAY_WINDOW"
  printf -- "#--interval-ms 16\r\n"
  printf "\r\n"
  printf "# Send every rectangle Raw instead of RRE where RRE is smaller.  Off\r\n"
  printf "# by default; it is for measuring what RRE buys.\r\n"
  printf -- "#--no-rre\r\n"
  printf "\r\n"
  printf "# The keyboard and mouse registers on the I/O board, and the switch\r\n"
  printf "# that turns the input half off altogether --- a screen to watch and\r\n"
  printf "# nothing carried back to the machine.  The default is the address\r\n"
  printf "# the fabric puts them at, with input on.\r\n"
  printf -- "#--input 0x40003000\r\n"
  printf -- "#--no-input\r\n"
  printf "\r\n"
  printf "# The SECOND screen, the color TV's, served as this one is. It needs\r\n"
  printf "# a color TV in the backplane --- see the display boards below ---\r\n"
  printf "# and it is pixels only: the machine has one keyboard and one mouse,\r\n"
  printf "# on the I/O board, and they stay with the main screen, so what a\r\n"
  printf "# viewer types or points at here is dropped. muir's own default is\r\n"
  printf "# the display above the main screen's, which is 5901; on this board\r\n"
  printf "# 5901 is muir's own machine and 5902 is muir's color screen, so\r\n"
  printf "# name a display of its own.\r\n"
  printf -- "#--color-terminal 0.0.0.0:5903\r\n"
  printf "\r\n"
  printf "# The color TV's region in memory. The default is where the fabric\r\n"
  printf "# puts the second window, 128 KB above the first.\r\n"
  printf -- "#--color-window %s\r\n" "$COLOR_WINDOW"
  printf "\r\n"
  printf "# The socket a source that is not a viewer sends keys and pointer\r\n"
  printf "# movement on, which is the board's own USB keyboard and mouse, and\r\n"
  printf "# the switch that stops listening for one.  The default is the path\r\n"
  printf "# the USB program connects to.\r\n"
  printf -- "#--input-link /var/run/cadr-input\r\n"
  printf -- "#--no-input-link\r\n"

  printf "\r\n"
  printf "# =================================================== the serial line\r\n"
  printf "# Read by the serial program, which offers the far end of the CADR's\r\n"
  printf "# RS-232 cable on TCP. docs/chaosnet.md has the section on it.\r\n"
  printf "\r\n"
  printf "# Where that far end is offered: a port, or address:port, which is\r\n"
  printf "# muir's own grammar for its own --serial, and the port must be\r\n"
  printf "# named.  WITHOUT THIS LINE THE SERIAL LINE IS OFF and the program\r\n"
  printf "# that serves it is not started, which is muir's own rule for its own\r\n"
  printf "# --serial: a line nobody asked for is a port nobody was told to\r\n"
  printf "# attach to.  Every interface, so that \`nc\` or telnet on another\r\n"
  printf "# machine reaches it; 127.0.0.1:7641 keeps it to this board.  7641 is\r\n"
  printf "# the 2651's own Unibus address, 0o764160.\r\n"
  printf -- "%s--serial %s\r\n" "$MENU_SERIAL" "$SERIAL_ENDPOINT"
  printf "\r\n"
  printf "# The port's register window, and how often it is looked at while\r\n"
  printf "# idle, in microseconds.  The defaults are where the fabric puts the\r\n"
  printf "# registers and an interval that keeps the port's store of 1,024\r\n"
  printf "# characters far from full at every rate the chip has.\r\n"
  printf -- "#--regs 0x40002000\r\n"
  printf -- "#--poll-us 2000\r\n"
  printf "\r\n"
  printf "# Do not say when a device plugs in or hangs up.  Off by default, so\r\n"
  printf "# the console shows somebody attaching to the line.\r\n"
  printf -- "#--quiet\r\n"

  printf "\r\n"
  printf "# ============================ the USB keyboard and mouse at the board\r\n"
  printf "# Read by the USB input program, which reads the board's own USB host\r\n"
  printf "# port and sends what it finds to the terminal program.  Every one of\r\n"
  printf "# these is spelled --usb- because the other spelling is a word\r\n"
  printf "# another program could want. docs/usb-input.md says what each means.\r\n"
  printf "\r\n"
  printf "# The socket the terminal program listens on, and where the evdev\r\n"
  printf "# nodes are.  The defaults are that socket and /dev/input, and a\r\n"
  printf "# board passes neither.\r\n"
  printf -- "#--usb-link /var/run/cadr-input\r\n"
  printf -- "#--usb-input-dir /dev/input\r\n"
  printf "\r\n"
  printf "# One device to read, instead of everything that looks like a\r\n"
  printf "# keyboard or a mouse.  Repeatable.  With none of these the program\r\n"
  printf "# opens what it finds and keeps looking, which is what a board wants.\r\n"
  printf -- "#--usb-device /dev/input/event0\r\n"
  printf "\r\n"
  printf "# How often to look for a device that has been plugged in, in\r\n"
  printf "# milliseconds.  The default is once a second.\r\n"
  printf -- "#--usb-scan-ms 1000\r\n"
  printf "\r\n"
  printf "# Take the devices exclusively, so that nothing else on the board\r\n"
  printf "# sees the keys.  Off by default: a grab that succeeds on a device\r\n"
  printf "# somebody is debugging with evtest is a keyboard that has silently\r\n"
  printf "# stopped answering them.\r\n"
  printf -- "#--usb-grab\r\n"
  printf "\r\n"
  printf "# Ignore keyboards, or ignore mice.  Both off by default, and both\r\n"
  printf "# together would leave the program nothing to read.\r\n"
  printf -- "#--usb-no-keyboard\r\n"
  printf -- "#--usb-no-mouse\r\n"

  printf "\r\n"
  printf "# ================================================ the display boards\r\n"
  printf "# Read by the disk pack program's init script, before the drive comes\r\n"
  printf "# present, and written into the console face. docs/tv.md has the\r\n"
  printf "# boards.\r\n"
  printf "\r\n"
  printf "# Which display board the first one is, muir's own --tv-board: MIT's\r\n"
  printf "# SIMPLE TV, which System 100 drives, or the LISPM TV that replaced\r\n"
  printf "# it in December 1980. The two program alike but for mode bit 7,\r\n"
  printf "# which reads the sync enable back on the LISPM TV and zero on the\r\n"
  printf "# SIMPLE TV. The default is simple-tv.\r\n"
  printf -- "#--tv-board simple-tv\r\n"
  printf "\r\n"
  printf "# Fit the SECOND display board, the color TV: a LISPM TV strapped to\r\n"
  printf "# 0o17200000 with its registers at 0o17377750, MIT's own \"for the\r\n"
  printf "# color TV, x is 5\". 576 x 454 at four bits a pixel through sixteen\r\n"
  printf "# colors. OFF BY DEFAULT, and that matters: a machine without it\r\n"
  printf "# answers those addresses with an NXM, which is how the band finds\r\n"
  printf "# out it has no color screen. Serve the picture with\r\n"
  printf "# --color-terminal above.\r\n"
  printf -- "#--color-tv\r\n"

  printf "\r\n"
  printf "# ================================================= the display output\r\n"
  printf "# Read by the disk pack program's init script, before the drive comes\r\n"
  printf "# present, and written into the console face. The display output scans\r\n"
  printf "# the display's region of memory at a monitor's rate and drives the\r\n"
  printf "# HDMI connector with no software in the path.\r\n"
  printf "# docs/display-output.md is the design.\r\n"
  printf "\r\n"
  printf "# Which screens go to the monitor: the first display, the color board,\r\n"
  printf "# or both. Whatever is shown is centered at 1:1 with the rest black,\r\n"
  printf "# and where both overlap the color one is drawn over the first. The\r\n"
  printf "# default is tv, the machine's own screen.\r\n"
  printf -- "#--hdmi-output tv\r\n"
  printf "\r\n"
  printf "# Which way up, for a monitor stood on its side. The CADR's screen is\r\n"
  printf "# 768 by 963, taller than it is wide, so a turned monitor holds it\r\n"
  printf "# with room where an upright one wastes the sides. 90 is a quarter\r\n"
  printf "# turn clockwise and -90 the other way. The default is 0.\r\n"
  printf -- "#--hdmi-rotate 0\r\n"
  printf "\r\n"
  printf "# How many seconds the display output waits with nobody at the board's\r\n"
  printf "# own keyboard or mouse before it stops the link, which is how a monitor\r\n"
  printf "# is put to sleep: a digital link has no other way. A key or the mouse\r\n"
  printf "# at the board wakes it; a viewer's keys do not. 0 never sleeps. The\r\n"
  printf "# default is 300, which the fabric comes up with.\r\n"
  printf "# \`cadr-console hdmi-sleep\` does the same thing at any time.\r\n"
  printf -- "#--hdmi-sleep 300\r\n"
  printf "\r\n"
  printf "# Which video mode the BITSTREAM carries, which this line asks about\r\n"
  printf "# rather than sets: a mode is a pixel clock, a pixel clock comes from\r\n"
  printf "# an MMCM, and an MMCM's dividers are fixed in the bitstream. A\r\n"
  printf "# bitstream carries one mode. A card naming one the fabric does\r\n"
  printf "# not carry gets a line saying which bitstream it wants.\r\n"
  printf -- "#--hdmi-mode 1280x1024\r\n"

  printf "\r\n"
  printf "# ========================================================= the clock\r\n"
  printf "# Read by the disk pack program's init script, before anything else\r\n"
  printf "# starts. This board has no real-time clock in it, so it comes up at\r\n"
  printf "# the epoch and does not know the date or the time until these two\r\n"
  printf "# lines tell it. The clock is UTC. docs/fpgarc.md has the section on\r\n"
  printf "# them.\r\n"
  printf "\r\n"
  printf "# The date, as a four-digit year then a two-digit month then a\r\n"
  printf "# two-digit day. Fill it in before uncommenting it: what stands below\r\n"
  printf "# is the form and not a date, so a line left as it is gets a line at\r\n"
  printf "# boot saying so rather than setting a day nobody meant.\r\n"
  printf -- "#--date yyyyMMdd\r\n"
  printf "\r\n"
  printf "# The time on a 24-hour clock, as the hour 00 to 23 then the minute,\r\n"
  printf "# then the second if it is wanted. There is no am and no pm, and both\r\n"
  printf "# 1438 and 143800 name the same instant.\r\n"
  printf -- "#--time HHmm\r\n"
  printf "\r\n"
  printf "# Either line may stand alone and sets only the field it names,\r\n"
  printf "# leaving the other exactly as it is. A time on its own is not that\r\n"
  printf "# time today: this board has no today, so the date stays where it\r\n"
  printf "# stood. The clock is saved to \`clock\` beside this file at a clean\r\n"
  printf "# shutdown and restored at the next boot, which is what gives the\r\n"
  printf "# board a date to leave alone, and a line here is set on top of it.\r\n"
  printf "# The two are never compared, so a line naming an instant earlier\r\n"
  printf "# than the saved clock is still the setting the board takes.\r\n"

  printf "\r\n"
  printf "# ========================================================= the lamps\r\n"
  printf "# Read by the disk pack program's init script, which asks the console\r\n"
  printf "# for it. docs/board.md has the lamps.\r\n"
  printf "\r\n"
  printf "# With this line the activity lamps hold a level instead of blinking:\r\n"
  printf "# the clock lamp is lit while the fabric has a clock and the microcycle\r\n"
  printf "# lamp while the machine runs, dark a moment after it stops. Without\r\n"
  printf "# it they blink, which is what the fabric comes up with.\r\n"
  printf "# \`cadr-console blinking-leds on|off\` does the same thing at any time.\r\n"
  printf -- "%s--no-blinking-leds\r\n" "$NO_BLINKING_LEDS_PREFIX"

  printf "\r\n"
  printf "# =================================================== the boot button\r\n"
  printf "# Read by the disk pack program's init script, before the drive comes\r\n"
  printf "# present. docs/fpgarc.md has the section on it.\r\n"
  printf "\r\n"
  printf "# With this line the machine is held at boot with RUN clear, as a\r\n"
  printf "# CADR is when the power comes on with nobody at the button, and\r\n"
  printf "# \`cadr-console boot\` or BTN0 on the board is what starts it.\r\n"
  printf "# Without it the board boots its band by itself.\r\n"
  printf "# SW0 on the board asks for the same thing, and the two are an OR:\r\n"
  printf "# a card can ask for a hold the switch did not, and this line can\r\n"
  printf "# never turn the switch off.\r\n"
  printf -- "%s--no-auto-boot\r\n" "$NO_AUTO_BOOT_PREFIX"

  printf "\r\n"
  printf "# ==================================================== the debug cable\r\n"
  printf "# Read by the disk pack program's init script, which asks the console\r\n"
  printf "# for it. docs/debug-cable.md has the cable.\r\n"
  printf "\r\n"
  printf "# MIT's debug cable is Pmod JA, both directions on one connector. A\r\n"
  printf "# board with this line commented out is a DEBUGGEE: it answers a\r\n"
  printf "# debugger that plugs into JA, which is what a CADR is with nothing\r\n"
  printf "# set, and nothing has to be said for it. Uncommented, this board asks\r\n"
  printf "# to be the DEBUGGER on the connector instead --- which is muir's own\r\n"
  printf "# flag and takes no argument, the connector being fixed in the\r\n"
  printf "# bitstream. There is no listen flag here or in muir, because\r\n"
  printf "# listening is what a CADR always does: this board's own register\r\n"
  printf "# window stays a debugger of its own either way, so the machine here\r\n"
  printf "# is debuggable while it debugs somebody else.\r\n"
  printf "# A board that can see a debugger already on the connector refuses,\r\n"
  printf "# and the console says so at boot; the first board told is the one\r\n"
  printf "# that has the role. \`cadr-console debug-cable-connect\` and\r\n"
  printf "# \`... -disconnect\` do the same thing at any time.\r\n"
  printf -- "#--debug-cable-connect\r\n"

  printf "\r\n"
  printf "# Which way round the JA ribbon was made. A Pmod cable is supposed to\r\n"
  printf "# join pin one to pin one; one made from two host sockets mirrors the\r\n"
  printf "# header's two rows instead, so each board's pins 1-4 reach the other's\r\n"
  printf "# 7-10 and a debugger drives four pins the far board never listens to.\r\n"
  printf "# Only a DEBUGGER applies this, so it changes nothing on a board that\r\n"
  printf "# is a debuggee. \`auto\` looks for the answer and is what the fabric\r\n"
  printf "# comes up with: the board drives nothing while it listens on both\r\n"
  printf "# groups, then assumes straight and tries the other wiring in turn\r\n"
  printf "# until something answers. \`straight\` and \`crossover\` take the\r\n"
  printf "# looking out of the way when somebody is diagnosing a cable.\r\n"
  printf "# \`cadr-console debug-cable-wiring auto|straight|crossover\` does the\r\n"
  printf "# same thing at any time, and \`cadr-console debug-cable\` says which\r\n"
  printf "# wiring the board found.\r\n"
  printf -- "%s--debug-cable-wiring auto\r\n" "$MENU_WIRING"
} > "$OUT/packs/fpgarc"
echo "mksd-buildroot: the lamps: $([ -z "$NO_BLINKING_LEDS_PREFIX" ] && echo "--no-blinking-leds --- steady, a level while the fabric is clocked and the machine runs" || echo "blinking, as the fabric comes up")"
echo "mksd-buildroot: the boot button: $([ -z "$NO_AUTO_BOOT_PREFIX" ] && echo "--no-auto-boot --- the machine is held at boot and cadr-console boot or BTN0 starts it" || echo "pressed at boot --- the board boots its band by itself")"
echo "mksd-buildroot: the Chaosnet: address $CHAOS_ADDR, the cable at $CABLE_ENDPOINT$([ -n "${CHAOS_PEER:-}" ] && echo ", $(set -- ${CHAOS_PEER}; echo $#) peer(s) from local.conf" || echo ", no peers --- the network is the user's")$([ -n "${CHAOS_DEFAULT_PEER:-}" ] && echo ", and a bridge for the rest" || echo ", and no bridge")"
echo "mksd-buildroot: the serial line: $([ -z "$MENU_SERIAL" ] && echo "offered at $SERIAL_ENDPOINT" || echo "OFF --- --serial is written commented out, and the program that serves it is not started")"

# --------------------------------------------------------- muir's file of flags
#
# The debugger is the word `muir` and nothing else.  muir reads
# --config if it is given, else `.muirrc` in the directory it was run from,
# else `.muirrc` in the home directory --- the FIRST of those and not all of
# them --- and a flag typed on the command line still wins over the file.  So
# this is a default and never a cage.
#
# **IT IS HERE AND NOT IN THE ROOT FILESYSTEM**, which is a RAM disk unpacked
# at every boot: an edit made to a file in there is lost at the next reset.
# The muir package installs /root/.muirrc as a symlink to this file, so a `muir`
# typed anywhere on the board finds it and somebody who changes a port changes
# it once.
#
# The format, out of muir's own main.rs: one flag a line, the flag then a space
# then the rest of the line as its argument --- so a path with a space in it
# needs no quoting --- and a line that is blank or starts with `#` is a comment.
# The file is called `muirrc` and not `.muirrc` because this partition is what
# a laptop shows somebody who puts the card in, and a dotfile is hidden there.
#
# **THE PORTS ARE muir'S OWN AND NOT THE FABRIC CADR'S.**  5900 is
# cadr-terminal's, 7641 cadr-serial's and 42042 cadr-chaosnet's, all serving
# the machine in the fabric.  The machine INSIDE muir is a second CADR and two
# stations on one port is a collision, not a network, so it takes 5901, 7642
# and 42043 --- which a VNC viewer reads as display 1 beside display 0, and
# which leave the fabric machine's numbers meaning what they meant.  A named
# port that cannot be bound stops the run, which is the failure worth having:
# an unnamed one goes looking for the first free display and would move under
# you between boots.
CHAOS_ADDR_M=${CHAOS_ADDR_MUIR:-177102}
CHAOS_PORT_M=${CHAOS_UDP_PORT_MUIR:-42043}
VNC_PORT_M=${MUIR_TERMINAL_PORT:-5901}
{
  printf "# muir's flags on this board: the debugger, so that it is the word\r\n"
  printf "# \`muir\` and nothing else.  One flag a line, the flag then a space\r\n"
  printf "# then the rest of the line as its argument; # is a comment.  A flag\r\n"
  printf "# typed on the command line wins over this file.\r\n"
  printf "#\r\n"
  printf "# /root/.muirrc on the board is a symlink to this file.  Edit it here,\r\n"
  printf "# on the card, where it survives a reboot.\r\n"
  printf "\r\n"
  printf "# The engine.  The debug cable is rtl's; micro has no timing model and\r\n"
  printf "# no end of the cable, and on chip the cable is the DBGIN end only.\r\n"
  printf -- "--rtl\r\n"
  printf "\r\n"
  printf "# The screen, on every interface rather than the loopback, so that a\r\n"
  printf "# VNC viewer on another machine can reach it.  RFB's None security is\r\n"
  printf "# the only type offered and a viewer needs no password.\r\n"
  printf -- "--terminal 0.0.0.0:%s\r\n" "$VNC_PORT_M"
  printf "\r\n"
  printf "# The Chaosnet.  muir is its own station on the cable, one address\r\n"
  printf "# along from the CADR in the fabric, on a port of its own.\r\n"
  printf -- "--chaos-address %s\r\n" "$CHAOS_ADDR_M"
  printf -- "--chaos-udp 0.0.0.0:%s\r\n" "$CHAOS_PORT_M"
  for peer in ${CHAOS_PEER:-}; do printf -- "--chaos-udp-peer %s\r\n" "$peer"; done
  # The way out for everything no peer line names, which is the bridge.  An
  # endpoint and no Chaosnet address, because it is not a host at an address:
  # it is the route of last resort, and the frame carries its real destination
  # for the bridge to route on.  A broadcast is not sent there.
  if [ -n "${CHAOS_DEFAULT_PEER:-}" ]; then
    printf -- "--chaos-udp-default-peer %s\r\n" "$CHAOS_DEFAULT_PEER"
  fi
  printf "\r\n"
  # **THE TWO LINES THAT FINISH THIS FILE GO IN LIVE OR COMMENTED, TOGETHER,
  # AND NEVER ONE OF EACH.**  They are one arrangement and not two settings: a
  # muir attached to the cable with no CC band is a debugger with no debugger
  # in it, and a muir with the band and no cable is a second CADR that debugs
  # nothing.  So the card that carries the pack writes both live and the card
  # that does not writes both commented, with the explanation the second case
  # needs.
  if [ -n "${CC_PACK:-}" ]; then
    printf "# THE PACK AND THE CABLE.  This card carries the debugger's band,\r\n"
    printf "# so both of these are live.\r\n"
    printf "#\r\n"
    printf "# The pack.  The debugger is not muir; it is CC running on a CADR\r\n"
    printf "# that muir simulates, so muir needs a band with CC already loaded\r\n"
    printf "# in it.  The name is not disk-pack-0.img to disk-pack-7.img:\r\n"
    printf "# those eight are the fabric machine's drive bay and this pack is\r\n"
    printf "# muir's own.  muir opens it read-write, as a drive writes a pack,\r\n"
    printf "# so this copy drifts from the first boot; that is what a drive\r\n"
    printf "# does and is not a fault.\r\n"
    printf -- "--disk-pack /mnt/packs/%s\r\n" "$CC_PACK_NAME"
    printf "#\r\n"
    printf "# The cable.  An argument beginning 0x is no endpoint but the\r\n"
    printf "# physical address where this project's CADR presents its DBGIN as\r\n"
    printf "# a register window, reached through /dev/mem.  THE ADDRESS IS\r\n"
    printf "# SETTLED: %s, the second 4 KB page of %s, behind\r\n" "$DEBUG_WINDOW_US" "$DEBUG_PORT"
    printf "# the split that shares that port with the console at %s.\r\n" "$CONSOLE_WINDOW_US"
    printf "# muir refuses a window that does not read DBUG, and has no default\r\n"
    printf "# for where one sits, so a bitstream without the cable in it stops\r\n"
    printf "# muir rather than letting it talk to nothing --- which is also\r\n"
    printf "# what this line does on a board holding an older bitstream.\r\n"
    printf -- "--debug-cable-connect %s\r\n" "$DEBUG_WINDOW"
  else
    printf "# NOT ON THIS CARD, AND THE TWO LINES THAT WOULD FINISH THIS FILE.\r\n"
    printf "#\r\n"
    printf "# The pack.  The debugger is not muir; it is CC running on a CADR\r\n"
    printf "# that muir simulates, so muir needs a band with CC already loaded.\r\n"
    printf "# This card carries no such pack.  Without it a \`muir\` typed here\r\n"
    printf "# boots the PROM and waits on a drive that never answers, which is\r\n"
    printf "# what a CADR with no pack loaded did.  The name must not be\r\n"
    printf "# disk-pack-0.img to disk-pack-7.img: those eight are the fabric\r\n"
    printf "# machine's drive bay and this pack is muir's own.\r\n"
    printf "#--disk-pack /mnt/packs/%s\r\n" "$CC_PACK_NAME"
    printf "#\r\n"
    printf "# The cable.  An argument beginning 0x is no endpoint but the\r\n"
    printf "# physical address where this project's CADR presents its DBGIN as\r\n"
    printf "# a register window, reached through /dev/mem.  THE ADDRESS IS\r\n"
    printf "# SETTLED: %s, the second 4 KB page of %s, behind\r\n" "$DEBUG_WINDOW_US" "$DEBUG_PORT"
    printf "# the split that shares that port with the console at %s.\r\n" "$CONSOLE_WINDOW_US"
    printf "# muir refuses a window that does not read DBUG, and has no default\r\n"
    printf "# for where one sits, so a bitstream without the cable in it stops\r\n"
    printf "# muir rather than letting it talk to nothing.  That is also why\r\n"
    printf "# this line stays commented while the pack above is missing: a card\r\n"
    printf "# that demanded the window would refuse to start on every older\r\n"
    printf "# bitstream.  Copy a pack in beside this file and uncomment the\r\n"
    printf "# two together.\r\n"
    printf "#--debug-cable-connect %s\r\n" "$DEBUG_WINDOW"
  fi
  printf "#\r\n"
  printf "# The serial line would be --serial 0.0.0.0:7642, one above the fabric\r\n"
  printf "# machine's 7641.  It is NOT here, and not by oversight: muir refuses\r\n"
  printf "# --serial together with any of the debug cable flags --- the serial\r\n"
  printf "# port is one machine's and a lashup runs two --- so the line above\r\n"
  printf "# and a --serial line cannot both be in this file.  The cable is what\r\n"
  printf "# this muir is for.\r\n"
} > "$OUT/packs/muirrc"
echo "mksd-buildroot: muir: terminal $VNC_PORT_M, Chaosnet address $CHAOS_ADDR_M port $CHAOS_PORT_M, $([ -n "${CHAOS_PEER:-}" ] && echo "$(set -- ${CHAOS_PEER}; echo $#) peer(s) from local.conf" || echo "no peer")$([ -n "${CHAOS_DEFAULT_PEER:-}" ] && echo " and a bridge" || echo ""); the cable is at $DEBUG_WINDOW and $([ -n "${CC_PACK:-}" ] && echo "is live, with the debugger's pack at /mnt/packs/$CC_PACK_NAME" || echo "waits on the CC pack")"

# The server: the same five files and the command that fetches them, in the
# directory named for this board.
[ -n "$NO_FABRIC" ] || cp "$BIT" "$OUT/server/$BOARD_NAME/$FABRIC"
cp "$IMAGES/$BOARD_DTB" "$IMAGES/$KERNEL" "$IMAGES/rootfs.cpio.uboot" "$OUT/server/$BOARD_NAME/"
cp "$BOARD/uEnv.net" "$OUT/server/$BOARD_NAME/uEnv.net"

# What makes the staging believable rather than merely done.
#
# BOOT.BIN is a Zynq boot image: the boot ROM looks for "XNLX" at offset 0x24
# (UG585, the boot header's image identification), and a file that is not
# that is a board parked in its ROM.  A board with no BOOT.BIN --- the
# DE25-Nano's first-stage loader is in its flash --- has nothing here to check.
if [ -f "$OUT/card/BOOT.BIN" ]; then
id=$(dd if="$OUT/card/BOOT.BIN" bs=1 skip=36 count=4 2>/dev/null)
[ "$id" = "XNLX" ] || die "BOOT.BIN does not carry the boot ROM's XNLX identification at 0x24"
fi
# u-boot.img is a FIT holding U-Boot proper and its tree --- the generic Zynq
# configuration's SPL loads a FIT (CONFIG_SPL_LOAD_FIT, no legacy-image
# support) and asks for it by that name (CONFIG_SPL_FS_LOAD_PAYLOAD_NAME) ---
# so it is a flattened tree whose /images node holds an image of type
# `firmware`.  Measured on the first build: mkimage -l prints nothing for it,
# which is why the check reads the FIT rather than trusting a listing.  And
# the U-Boot inside it must be the one whose environment boots this card:
# bootcmd=run cadr_boot with a cadr_card, or the card path does not exist.
# The DE25-Nano's u-boot.itb is the same shape, and its `firmware` is TF-A's
# BL31 (arch/arm/dts/socfpga_soc64_fit-u-boot.dtsi); `$LOADER` is whichever
# the board's loader reads.
if [ -x "$HOSTBIN/fdtget" ]; then
  found=no
  for img in $("$HOSTBIN/fdtget" -l "$OUT/card/$LOADER" /images 2>/dev/null); do
    [ "$("$HOSTBIN/fdtget" "$OUT/card/$LOADER" "/images/$img" type 2>/dev/null)" = firmware ] && found=yes
  done
  [ "$found" = yes ] || die "$LOADER is not a FIT with a firmware image in it"
fi
# **AND THE CARD PATH IS ASKED FOR IN TWO PARTS, BECAUSE IT IS IN TWO PARTS ON
# ONE OF THE BOARDS.**  `cadr_card` must be there and the fabric's image must
# be fetched from the card, and on the Zynq boards those are one line:
# FABRIC_FETCH is `cadr_card` and this asks exactly what it always asked.  On
# the DE25-Nano the fetch is `cadr_rbf_card`, a variable of its own, so asking
# for `cadr_card=load mmc 0:1` there refused every loader built since the
# fabric's image stopped being fetched on the path that does not load it.
for var in "bootcmd=run cadr_boot" "cadr_card=" "$FABRIC_FETCH=load mmc 0:1" \
           "cadr_net=" "$LAST_STEP="; do
  strings "$OUT/card/$LOADER" | grep -q "^$var" || die "the U-Boot in $LOADER has no '$var' in its environment"
done
# AND IT MUST LOAD THE BOARD'S FOUR FILES FROM THE BOARD'S OWN FOLDER, which
# is the card half of the mirror and is checked at both ends here.  A U-Boot
# built before the card mirrored the server loads cadr.bit from the root of
# the partition, where this script no longer puts it, so it would loop saying
# it cannot find a file --- loudly, but at the board rather than here.  The
# refusal names the cure, because Buildroot does not watch this repository's
# files and a plain `make buildroot` leaves a stale environment in place once
# the package has a build stamp.
#
# **THE FABRIC'S IMAGE IS ASKED OF THE VARIABLE THAT FETCHES IT**, which is
# `cadr_card` on the Zynq boards and `cadr_rbf_card` on the DE25-Nano.  What
# this holds is the FOLDER and not where the fetch lives: a loader that looked
# for a board's file at the root of the partition would be handed another
# board's, and that is as true of the fabric's image as of the other three.
# The file ends its own line where the fetch is a variable of one line, so
# either a space or the end of the line follows it.
strings "$OUT/card/$LOADER" | grep -q "^$FABRIC_FETCH=.*$BOARD_NAME/$FABRIC\( \|$\)" \
  || die "the U-Boot in $LOADER does not load $BOARD_NAME/$FABRIC from the card in $FABRIC_FETCH: it predates the card mirroring the server, and 'make $REBUILD' is what rewrites it"
for f in $BOARD_DTB $KERNEL rootfs.cpio.uboot; do
  strings "$OUT/card/$LOADER" | grep -q "cadr_card=.*$BOARD_NAME/$f " \
    || die "the U-Boot in $LOADER does not load $BOARD_NAME/$f from the card: it predates the card mirroring the server, and 'make $REBUILD' is what rewrites it"
done
# BOTH ENDS OF THE SERVED-DIRECTORY RULE ARE CHECKED RATHER THAN BELIEVED.
# The U-Boot on the card fetches this board's uEnv.net from this board's
# directory, and the uEnv.net it then reads names the other four the same
# way.  A U-Boot built before the rule, or a uEnv.net edited back to the flat
# names, is a board that fetches another board's files --- which on this
# server is a bitstream for the wrong part, and it is silent.
strings "$OUT/card/$LOADER" | grep -q "^cadr_net=.*$BOARD_NAME/uEnv.net" \
  || die "the U-Boot in $LOADER does not fetch $BOARD_NAME/uEnv.net: it predates the served-directory rule"
for f in $BOARD_DTB $KERNEL rootfs.cpio.uboot; do
  grep -q "tftpboot [^ ]* $BOARD_NAME/$f " "$OUT/server/$BOARD_NAME/uEnv.net" \
    || die "the served uEnv.net does not fetch $BOARD_NAME/$f"
done
# **AND THE FABRIC'S IMAGE ON THE NETWORK PATH, WHEREVER THAT PATH FETCHES
# IT.**  The Zynq boards' served netcmd fetches all four files itself.  The
# DE25-Nano's names `cadr_rbf_net` instead, which is in the loader's own
# environment, so the folder is asked of the loader there.  Either way the
# question is the same one: the folder, and not which file says it.
if [ -n "$FABRIC_FETCH_NET" ]; then
  strings "$OUT/card/$LOADER" | grep -q "^$FABRIC_FETCH_NET=.*$BOARD_NAME/$FABRIC\( \|$\)" \
    || die "the U-Boot in $LOADER does not fetch $BOARD_NAME/$FABRIC over TFTP in $FABRIC_FETCH_NET: it predates the served-directory rule, and 'make $REBUILD' is what rewrites it"
else
  grep -q "tftpboot [^ ]* $BOARD_NAME/$FABRIC\( \|$\)" "$OUT/server/$BOARD_NAME/uEnv.net" \
    || die "the served uEnv.net does not fetch $BOARD_NAME/$FABRIC"
fi
if [ -x "$HOSTBIN/mkimage" ]; then
  "$HOSTBIN/mkimage" -l "$OUT/server/$BOARD_NAME/rootfs.cpio.uboot" | grep -q "RAMDisk" || die "rootfs.cpio.uboot is not a U-Boot ramdisk image"
fi
# The tree reserves the CADR's memory, no-map, and describes no PL
# peripheral: decompiled with the dtc Buildroot built, or one on the path.
command -v "$DTC" >/dev/null 2>&1 || DTC=dtc
if command -v "$DTC" >/dev/null 2>&1; then
  "$DTC" -I dtb -O dts -o "$OUT/tree.dts" "$OUT/card/$BOARD_NAME/$BOARD_DTB" 2>/dev/null
  grep -q "$RESERVED" "$OUT/tree.dts" || die "the tree has no $RESERVED node"
  grep -A4 "$RESERVED" "$OUT/tree.dts" | grep -q 'no-map' || die "the tree's reservation is not no-map"
  [ -z "$PL_NODE" ] || ! grep -q "$PL_NODE" "$OUT/tree.dts" || die "the tree describes PL peripherals"
  # Which board's tree it is, read out of the board's own source rather than
  # written here a second time: two spellings of one model string would part
  # company on the first board that changed it.
  DTS=$BOARD/$DTS_DIR/${BOARD_DTB%.dtb}.dts
  MODEL=$(sed -n 's/^[[:space:]]*model = "\(.*\)";.*/\1/p' "$DTS" | head -1)
  [ -n "$MODEL" ] || die "no model string in $DTS"
  grep -q "\"$MODEL\"" "$OUT/tree.dts" || die "the tree's model is not \"$MODEL\": it is not this board's"
  # **AND ON THE DE25-Nano, U-BOOT'S OWN TREE TOO.**  There U-Boot proper runs
  # with the tree binman packs into u-boot.itb, and that tree is the one whose
  # `lmb` keeps the kernel's tree and the ramdisk out of the CADR's region.
  # Altera's DE25 configuration packs ITS tree there; ours is packed only
  # because socfpga_agilex5_de25_nano_cadr-u-boot.dtsi says so, and nothing
  # else would notice if it stopped.  So the tree is taken back out of the FIT
  # and looked at.  A Zynq board's u-boot.img carries its tree the same way,
  # and there the kernel's reservation and U-Boot's come from one file listed
  # for both, so this is the DE25-Nano's alone.
  if [ "$LOADER" = u-boot.itb ]; then
    [ -x "$HOSTBIN/dumpimage" ] && [ -x "$HOSTBIN/fdtget" ] \
      || die "no dumpimage or fdtget in $HOSTBIN to read U-Boot's tree out of u-boot.itb"
    at=0; pos=
    for img in $("$HOSTBIN/fdtget" -l "$OUT/card/u-boot.itb" /images); do
      [ "$("$HOSTBIN/fdtget" "$OUT/card/u-boot.itb" "/images/$img" type)" = flat_dt ] && pos=$at
      at=$((at + 1))
    done
    [ -n "$pos" ] || die "u-boot.itb carries no tree"
    "$HOSTBIN/dumpimage" -T flat_dt -p "$pos" -o "$OUT/uboot-tree.dtb" "$OUT/card/u-boot.itb" >/dev/null \
      || die "dumpimage could not take the tree out of u-boot.itb"
    "$DTC" -I dtb -O dts -o "$OUT/uboot-tree.dts" "$OUT/uboot-tree.dtb" 2>/dev/null
    grep -A4 "$RESERVED" "$OUT/uboot-tree.dts" | grep -q 'no-map' \
      || die "the tree U-Boot runs with (in u-boot.itb) has no $RESERVED, no-map: it is not ours, and U-Boot would place the kernel's tree and the ramdisk without knowing where the CADR's memory is"
    grep -q "\"$MODEL\"" "$OUT/uboot-tree.dts" || die "the tree in u-boot.itb is not \"$MODEL\""
    rm -f "$OUT/uboot-tree.dtb" "$OUT/uboot-tree.dts"
  fi
else
  echo "mksd-buildroot: no dtc; the tree was not checked" >&2
fi
# The card and the server hold the same four files, byte for byte, under the
# same folder name --- which is the whole of what "the card mirrors the server"
# claims, compared rather than asserted.
for f in $STAGED_FILES; do
  cmp -s "$OUT/card/$BOARD_NAME/$f" "$OUT/server/$BOARD_NAME/$f" \
    || die "$f differs between card/$BOARD_NAME/ and server/$BOARD_NAME/"
done
# And nothing of the board's is left at the root of the boot partition, where
# a stale copy would be read by nobody and would still look like the file.
for f in $BOARD_FILES; do
  if [ -e "$OUT/card/$f" ]; then
    die "card/$f is at the root of the boot partition, where nothing reads it"
  fi
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
  CADR_BOOT_SIZE="${BOOT_MB}M" CADR_PACKS_SIZE="${PACKS_MB}M" PATH="$HOSTBIN:$PATH" "$HOSTBIN/genimage" \
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
    # Partition 1's root: the three files whose names are fixed, and nothing
    # else of the board's.  Then the board's own folder, read back by the path
    # U-Boot will use --- which is what says the mirror survived genimage, and
    # not a listing.
    for f in "$OUT"/card/*; do
      [ -d "$f" ] && continue
      n=$(basename "$f")
      "$HOSTBIN/mcopy" -n -i "$OUT/sdcard.img@@$P1_OFF" "::$n" "$TMP/readback" 2>/dev/null \
        || die "$n is not at the root of partition 1 of sdcard.img"
      cmp -s "$f" "$TMP/readback" || die "$n in sdcard.img differs from card/$n"
    done
    for f in "$OUT/card/$BOARD_NAME"/*; do
      n=$(basename "$f")
      "$HOSTBIN/mcopy" -n -i "$OUT/sdcard.img@@$P1_OFF" "::/$BOARD_NAME/$n" "$TMP/readback" 2>/dev/null \
        || die "$BOARD_NAME/$n is not in partition 1 of sdcard.img: the card does not mirror the server"
      cmp -s "$f" "$TMP/readback" \
        || die "$BOARD_NAME/$n in sdcard.img differs from card/$BOARD_NAME/$n"
    done
    # AND THE ROOT HOLDS THE THREE FIXED NAMES AND THE BOARD'S FOLDER AND
    # NOTHING ELSE.  mdir marks a directory with a trailing slash, so this
    # tells the folder from a file of the same name; a fourth file at the root
    # is one nothing reads, and this is the only place that would say so.
    for n in $("$HOSTBIN/mdir" -b -i "$OUT/sdcard.img@@$P1_OFF" :: 2>/dev/null | sed 's,^::/,,'); do
      case " $ROOT_NAMES uEnv.txt $BOARD_NAME/ " in
        *" $n "*) ;;
        *) die "the root of partition 1 carries '$n', which is none of the fixed names ($ROOT_NAMES uEnv.txt) and is not $BOARD_NAME/" ;;
      esac
    done
    for f in "$OUT"/packs/*; do
      [ -e "$f" ] || continue
      n=$(basename "$f")
      # **THE BAND'S SOURCES ARE A TREE, AND A TREE IS READ BACK AS ONE.**
      # mcopy takes one file at a time, and this loop used to hand it a
      # directory and die saying the directory was not in the image --- which
      # is what a card carrying the sources did, because nothing had ever
      # staged one through genimage.  So a directory is pulled out of the
      # image whole and compared against what was staged, file by file.
      # Skipping it instead would have been five hundred files nobody looked
      # at, on the one partition the board writes to.
      if [ -d "$f" ]; then
        rm -rf "$TMP/readtree"; mkdir -p "$TMP/readtree"
        "$HOSTBIN/mcopy" -n -s -i "$OUT/sdcard.img@@$P2_OFF" "::/$n" "$TMP/readtree/" 2>/dev/null \
          || die "$n/ is not in partition 2 of sdcard.img"
        diff -r "$f" "$TMP/readtree/$n" > "$TMP/treediff" 2>&1 \
          || { sed 's/^/  /' "$TMP/treediff" >&2; die "$n/ in sdcard.img differs from packs/$n/"; }
        echo "mksd-buildroot: packs/$n/ read back out of the image:" \
             "$(find "$TMP/readtree/$n" -type f | wc -l) file(s), every one identical"
        rm -rf "$TMP/readtree" "$TMP/treediff"
        continue
      fi
      "$HOSTBIN/mcopy" -n -i "$OUT/sdcard.img@@$P2_OFF" "::$n" "$TMP/readback" 2>/dev/null \
        || die "$n is not in partition 2 of sdcard.img"
      cmp -s "$f" "$TMP/readback" || die "$n in sdcard.img differs from packs/$n"
    done
    # And NOTHING BUT PACKS on partition 2: the program takes eight names, so
    # a ninth file there is a file nobody will ever read.
    for n in $("$HOSTBIN/mdir" -b -i "$OUT/sdcard.img@@$P2_OFF" :: 2>/dev/null | sed 's,^::/,,'); do
      case "$n" in
        disk-pack-[0-7].img|README.TXT) ;;
        fpgarc|muirrc) ;;
        # The band's sources, which mdir marks as a directory with a trailing
        # slash.  It is named rather than swept in with every directory,
        # because `--ozd-root sys=/mnt/packs/sys,ro` names this one tree and
        # a second directory here would be one nothing on the board reads.
        sys/) ;;
        # A variable and not the literal muir-cc.img, so that the name lives
        # in one place: it is written into muirrc as well, and two spellings
        # of it would part company on the first one somebody changed.
        "$CC_PACK_NAME") ;;
        *) die "partition 2 carries '$n', which is none of the eight pack names, the README, or a settings file" ;;
      esac
    done
    rm -f "$TMP/readback"
  fi
else
  echo "mksd-buildroot: no genimage in $HOSTBIN; only the loose files are staged" >&2
fi

echo "staged $OUT"
echo "  $MODE"
(cd "$OUT/card" && for f in *; do [ -f "$f" ] || continue; printf '  card/    %-22s %10d  %s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -c1-16)"; done)
(cd "$OUT/card/$BOARD_NAME" && for f in *; do printf "  card/$BOARD_NAME/ %-22s %10d  %s\n" "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -c1-16)"; done)
(cd "$OUT/packs" && for f in *; do
   [ -e "$f" ] || continue
   # A tree has no digest, so it is summed by what it costs the card: the
   # files in it and the clusters they take, which is the term the partition
   # was sized on.
   if [ -d "$f" ]; then
     printf '  packs/   %-22s %10d  %s\n' "$f/" \
       "$(( $(du -s --block-size=4096 "$f" | cut -f1) * 4096 ))" \
       "$(find "$f" -type f | wc -l) file(s)"
     continue
   fi
   printf '  packs/   %-22s %10d  %s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -c1-16)"
 done)
(cd "$OUT/server/$BOARD_NAME" && for f in *; do printf "  server/$BOARD_NAME/ %-22s %10d  %s\n" "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -c1-16)"; done)
echo "  the card mirrors the server: card/$BOARD_NAME/ holds the same four files as"
echo "  server/$BOARD_NAME/, and only $(echo "$ROOT_NAMES" | sed 's/ /, /g') and uEnv.txt are at the root"
[ -z "$NO_FABRIC" ] || echo "  (and the fabric's slot, $BOARD_NAME/$FABRIC, is EMPTY on both: NO_FABRIC=1)"
echo "  the served set goes to the server's own directory for this board:"
echo "    mkdir -p /srv/tftp/$BOARD_NAME && cp $OUT/server/$BOARD_NAME/* /srv/tftp/$BOARD_NAME/"
[ -f "$OUT/sdcard.img" ] && printf '  %-31s %10d  %s\n' sdcard.img "$(stat -c %s "$OUT/sdcard.img")" "$(sha256sum "$OUT/sdcard.img" | cut -c1-16)"
if [ -f "$OUT/sdcard.img" ]; then
  echo "  partition 1 at byte $P1_OFF, $P1_MB MiB, FAT32 BOOT   --- the loader and the boot files; Linux mounts it read-only"
  echo "  partition 2 at byte $P2_OFF, $P2_MB MiB, FAT32 PACKS  --- the disk packs and the settings files, at /mnt/packs, read-write"
fi
if [ -z "$PACKS" ]; then
  echo "  (no PACKS given: the bay is empty.  Copy a pack to the running board as"
  echo "   /mnt/packs/disk-pack-N.img and that unit's drive comes ready with no restart;"
  echo "   docs/boot.md, \"The drive bay\".)"
fi
exit 0
