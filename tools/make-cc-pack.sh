#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build the debugger's disk pack: System 304 with CC compiled into the band.
#
# muir on the board is the far end of the debug cable, and the debugger is not
# muir. The debugger is CC, running on the CADR muir simulates. So muir on the
# board needs a band to boot, and that band needs CC on it. muir's own test for
# that band, `tests/cc_304.rs` until muir removed it at its commit 5328c26, got
# CC by compiling it over the Chaosnet FILE service from a host on the model
# network. That is fine on a build host and wrong on the board, where it would
# mean standing a Chaosnet file host up beside muir before the debugger could
# exist at all. This compiles CC once, here, and saves the world back into a
# partition of the pack. On the board the debugger is then a pack you boot.
#
# The mechanism for saving a band is MIT's own `SI:DISK-SAVE`
# (`sys/qmisc.lisp:1157`). Its second argument is `NO-QUERY`, and with that
# true the routine asks the keyboard nothing at all. It ends in the
# `%DISK-SAVE` microcode operation, which writes the world into the partition
# and then swaps it back in from there rather than returning. The machine
# carries on from the band it has just written, with a fresh herald and a
# who-line saying it cold-booted. muir opens a pack read-write, so every block
# the save writes goes to the file.
#
# WHAT THIS PRODUCES. A T-300 pack, 269,562,880 bytes, which is the base pack
# with a new band in one of its spare partitions and the label's current band
# pointing at it. Every pack this project makes is a T-300.
#
# THE BASE PACK NEED NOT BE THE RELEASE'S, AND WHICH ONE IT IS DECIDES THE REST.
# A band identifies itself, finds its associated machine and gets its date from
# the site files its file host serves, so a base pack whose band belongs to
# another network wants that network's site files under the file service's root
# and that network's Chaosnet numbers on the cable. `BASE` says which pack to
# start from, `SITE` says whose site files to serve, and `CC_PACK_CHAOS`,
# `CC_PACK_SERVER` and `CC_PACK_SERVER_NAME` say where the machine and its file
# host answer. Left alone, the last four are the System 304 release's own.
#
# **NOTHING IS FETCHED ANY MORE, SO THE RELEASE IS NAMED.** This script used to
# run muir's `tools/fetch-system-304.sh`, which brought in the System 304 pack
# and its sources and checked both. muir removed that script at its commit
# 5328c26, when it stopped testing System 304, so `BASE` and `SOURCES` must
# both be given and the script refuses at its start, saying what they are,
# when either is missing. The two files are assets of muir's GitHub release
# `system-304-0`, and the removed script, at 5328c26's parent, has the whole
# account of where they came from.
#
# IT IS NOT BYTE-REPRODUCIBLE, AND THAT IS A PROPERTY OF THE THING. A band is
# a dump of a running Lisp world, and the world carries the date, the random
# state, the compiler's gensym counters and whatever the paging happened to
# leave where. Two runs of this script produce two packs that both boot and
# both have CC, and they do not have the same digest. What is reproducible is
# the procedure, so the script prints the digest of what it made and that
# digest is what a particular pack is identified by afterwards.
#
# WHY THE PROGRAM IS ONE OF muir'S TESTS. The Chaosnet server that serves the
# release as `SYS:` lives in muir's `tests/support/`, not in its library, so
# nothing outside a test binary can compile a Lisp file on a simulated CADR.
# `tools/cc-pack/cc_pack.rs` is this repository's file; the script copies it
# beside muir's own tests in a build tree of its own and never writes to the
# muir checkout it was given.
#
# usage: tools/make-cc-pack.sh [<output pack>]
#
# The environment says where things are:
#
#   MUIR        the muir checkout to build from. Default ../muir.
#   WORK        where the build tree, the pack and the file service's root go.
#               Default $HOME/.cache/muir-fpga-cc-pack. It needs about 1 GB.
#   BASE        the pack to start from, copied and never written to itself.
#               Required. The release's is `disk-sys-304-0.img.gz` decompressed.
#   SOURCES     the System 304 system sources, the directory the band reads as
#               `SYS:`, copied under the file service's root. Required. The
#               release's is `sys-304-0.tar.gz` unpacked, its `sys-304-0`.
#   SITE        a directory of site files copied over the release's own
#               `sys/site` under the file service's root, so that the band
#               reads the host table, the machine locations and the logical
#               pathname translations of the network it belongs to. Default
#               none, which leaves the release's site files in place.
#   BAND        the partition the world is saved into. Default LOD3. It must
#               be an empty one: the release pack has LOD3 free and a base
#               pack with a band of its own in LOD3 wants the next.
#   CC_PACK_CHAOS, CC_PACK_SERVER, CC_PACK_SERVER_NAME
#               the machine's own Chaosnet address, its file and time host's
#               address, and that host's name. Octal, octal and a name.
#               Default 4401, 4403 and OZ, which are the release band's.
#   KEEP_WORK   set to anything to leave the work directory behind.
#
# It takes about an hour, nearly all of it the sixteen files of CC being
# compiled on the simulated machine.

set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$here/build/muir-cc-304.img}
muir=${MUIR:-$(cd "$here/../muir" 2>/dev/null && pwd || echo "")}
work=${WORK:-$HOME/.cache/muir-fpga-cc-pack}
band=${BAND:-LOD3}
site=${SITE:-}
chaos=${CC_PACK_CHAOS:-4401}
server=${CC_PACK_SERVER:-4403}
server_name=${CC_PACK_SERVER_NAME:-OZ}

if [ -z "$muir" ] || [ ! -f "$muir/Cargo.toml" ]; then
    echo "make-cc-pack: no muir checkout; set MUIR to one" >&2
    exit 2
fi

# The release, named, because nothing fetches it: see the header.
if [ -z "${BASE:-}" ] || [ -z "${SOURCES:-}" ]; then
    cat >&2 <<'EOF'
make-cc-pack: BASE and SOURCES must both be set, and nothing fetches them.
  muir's tools/fetch-system-304.sh brought the System 304 release in and muir
  removed it at its commit 5328c26.  The two files are assets of muir's
  GitHub release system-304-0:
    BASE     the pack: disk-sys-304-0.img.gz, decompressed.  SHA-256 of the .gz
             87f0434b54dd86fa1df5251b04e0c48b86c804fa5c5fc6faba6dafa818e2e584
    SOURCES  the system sources: sys-304-0.tar.gz, unpacked, and its sys-304-0
             directory named.  SHA-256 of the .tar.gz
             c945a464bfbed337358e79ba4ace8ef73c331e3a3a6c94c2c053624a463dfab1
EOF
    exit 2
fi
if [ ! -f "$BASE" ]; then
    echo "make-cc-pack: BASE is $BASE and there is no pack there" >&2
    exit 2
fi
if [ ! -d "$SOURCES" ]; then
    echo "make-cc-pack: SOURCES is $SOURCES and there is no directory there" >&2
    exit 2
fi
if [ -e "$out" ]; then
    echo "make-cc-pack: $out is there already; move it away if you mean to" >&2
    exit 2
fi

if [ -n "$site" ] && [ ! -d "$site" ]; then
    echo "make-cc-pack: SITE is $site and there is no directory there" >&2
    exit 2
fi

commit=$(git -C "$muir" rev-parse HEAD 2>/dev/null || echo unknown)
echo "make-cc-pack: muir at $commit, band $band, work $work"
echo "make-cc-pack: the machine at $chaos, $server_name at $server"

# A build tree of our own, so that the muir checkout is never written to: the
# compiled QFASLs go under it, and the test file this repository owns is copied
# into its tests.
mkdir -p "$work"
tree=$work/muir
rm -rf "$tree"
mkdir -p "$tree"
tar cf - -C "$muir" --exclude=.git --exclude=target --exclude=vendor . | tar xf - -C "$tree"
cp "$here/tools/cc-pack/cc_pack.rs" "$tree/tests/cc_pack.rs"

# The pack is a copy. A base pack given by name is left alone, and the machine
# writes to the copy from its first cold boot onward.
base=$BASE
echo "make-cc-pack: the base pack is $base"
pack=$work/pack.img
rm -f "$pack"
cp "$base" "$pack"
# A base pack kept read-only so that nothing can run against it by accident
# copies to a read-only file, and the machine has to write to this one.
chmod u+w "$pack"

# The FILE service's root, with the release's sources under `sys` as this
# band's own translations ask for them. A COPY and not muir's link, because
# `make-system :compile` writes every QFASL back through the file service and
# the vendored sources must not be what it writes into.
root=$work/file-root
rm -rf "$root"
mkdir -p "$root/tmp"
cp -a "$SOURCES" "$root/sys"

# And the site files of the network the band belongs to, over the release's
# own. A band asks its file host for the host table, the machine locations,
# the site definition and the logical pathname translations every time it cold
# boots, so these are what decide the name it calls itself, the associated
# machine its herald names and the host it asks for the date. A base pack from
# another network boots as nobody at all without them.
if [ -n "$site" ]; then
    echo "make-cc-pack: the site files come from $site"
    cp -a "$site"/. "$root/sys/site/"
fi

export CC_PACK=$pack
export CC_PACK_ROOT=$root
export CC_PACK_BAND=$band
export CC_PACK_CHAOS=$chaos
export CC_PACK_SERVER=$server
export CC_PACK_SERVER_NAME=$server_name
export CARGO_TARGET_DIR=$work/target

run() {
    ( cd "$tree" && cargo test --release --test cc_pack -- --ignored --nocapture --exact "$1" )
}

diskpack() {
    ( cd "$tree" && cargo run --release --quiet --bin diskpack -- "$@" )
}

echo "make-cc-pack: compiling CC on the machine and saving the band ..."
run builds_the_cc_pack

# The label: the band that was just saved becomes the one the machine offers.
# `%DISK-SAVE` does not set it, so somebody has to, and it is done here rather
# than at the machine's own listener because the listener the save leaves
# behind already belongs to the new band.
echo "make-cc-pack: pointing the label at $band"
diskpack "$pack" current "$band"
diskpack "$pack" show

# And it boots, with CC in it. This is the check that the pack is the thing it
# is meant to be, and it runs against the label the board will run against.
echo "make-cc-pack: booting the saved band ..."
run the_saved_band_has_cc

mkdir -p "$(dirname "$out")"
cp "$pack" "$out.part"
mv "$out.part" "$out"

# The screens the run recorded: what the machine was showing at each step,
# which is the only picture of an hour that nobody watched. They go beside the
# pack because the file service's root does not survive the cleanup.
shots=$(dirname "$out")/$(basename "$out" .img)-screens
rm -rf "$shots"
mkdir -p "$shots"
# An unmatched glob comes through as the pattern itself, and a test that fails
# as the last command of a loop body takes the whole script down under `set -e`.
for p in "$root"/cc-pack-*.png; do
    if [ -e "$p" ]; then
        cp "$p" "$shots/"
    fi
done

# The fetched release stays; everything else is a few minutes to make again.
[ -n "${KEEP_WORK:-}" ] || rm -rf "$work/target" "$root" "$pack" "$tree"

echo
echo "make-cc-pack: $out"
ls -l "$out"
sha256sum "$out" 2>/dev/null || shasum -a 256 "$out"
echo "made from muir $commit, System 304, CC saved in $band"
echo "base $base, the machine at $chaos with $server_name at $server"
