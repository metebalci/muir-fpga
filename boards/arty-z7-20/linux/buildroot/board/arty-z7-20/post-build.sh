#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# THE IMAGE HOLDS ONLY THE PROGRAMS THE PACKAGES INSTALL.
#
# **Why this exists.**  Buildroot builds `output/target/` up and never removes
# what a package stopped installing.  Rename a package and the old program and
# the old init script STAY THERE, and the image ships both.  That happened:
# the rename from `cadr-pack-feeder` to `cadr-disk-pack` left
# `usr/bin/cadr-pack-feeder` and `etc/init.d/S80cadr-pack-feeder` behind, so
# every boot after it started TWO disk pack programs, each mapping the same
# registers, each serving blocks and each writing blocks back to the same
# file.  The pack did not survive it, and the investigation blamed the disk
# channel for a day.  CLAUDE.md's entry is "THE CHANNEL WAS INNOCENT".
#
# So: a program or an init script in the target that no package in this tree
# installs is a FAILURE, not a warning, and it fails here --- during
# `target-finalize`, BEFORE the root filesystem image is written --- so no
# image containing the ghost is ever produced.  Buildroot runs this from
# BR2_ROOTFS_POST_BUILD_SCRIPT in configs/arty_z7_20_defconfig, on every
# `make buildroot` and every `make buildroot-rebuild`; nobody has to remember
# it and it costs one `find` over the target.
#
# **Why an assertion and not a clean target directory.**  Those were the two
# shapes named when the bug was found.  Building from a clean target means
# deleting every package's install stamp, which is a full rebuild --- 25
# minutes on 16 cores --- so it would be skipped, and a guard that is skipped
# is not a guard.  This costs milliseconds and, when it fires, NAMES THE FILES
# and prints the one-line remedy.  The two shapes are not alternatives of
# equal worth: the assertion is the one somebody will actually run.
#
# **Why not Buildroot's own `packages-file-list.txt`.**  Buildroot writes
# $(BUILD_DIR)/packages-file-list.txt from `$(BUILD_DIR)/*/.files-list.txt`,
# which reads like a manifest of what the packages install and is not one: the
# wildcard picks up the build directory of every package that EVER built here,
# including ones that no longer exist.  Measured on this build host at the
# time of the plural rename, that file still claimed
#
#     cadr-pack-feeder,./usr/bin/cadr-pack-feeder
#     cadr-tools,./usr/bin/cadr-pack-feeder
#
# for two packages deleted a day earlier --- so a guard trusting it would have
# called the ghost legitimate, which is exactly the case it exists to catch.
# The expected set is therefore derived from the SOURCE TREE, which is the
# only statement of what the packages install today.
#
# **The three checks, and why each is here.**
#
#   1. STALE.  Every file in the target whose name carries `cadr` must be at a
#      path some enabled package installs.  This is the historical bug.
#   2. MISSING.  Every path an enabled package installs must be in the target.
#      Without this the guard could pass by deriving nothing: an empty
#      expected set makes check 1 vacuous, and a check that cannot fail is not
#      a check.  It also catches a package that built and did not install.
#   3. CONFIGURED.  Every config symbol a package declares must appear in the
#      built `.config`, and every `BR2_PACKAGE_CADR_*=y` in a defconfig must be
#      a symbol some package declares.  A half-done rename --- the directory
#      moved and Config.in or the defconfig not --- silently drops the package
#      from the image, and then checks 1 and 2 agree about a smaller machine
#      than the one that was asked for.
#
# **What it does not reach.**  A ghost whose name carries no `cadr` --- a
# program of ours renamed out of that namespace, or a stale file from an
# upstream Buildroot package --- is invisible to check 1, because nothing in
# Buildroot records what an upstream package installed in a way that survives
# the package going away (see the paragraph above).  Check 2 still catches our
# own side of that: the new name is expected and missing.  Say so rather than
# claim more.

set -eu

TARGET=${1:?post-build.sh: no target directory}

BOARD=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
EXT=$(CDPATH= cd -- "$BOARD/../.." && pwd)
PKGDIR=$EXT/package

# Buildroot hands post-build scripts $O in EXTRA_ENV (package/Makefile.in), and
# the target directory is $O/target either way, so the config is reachable with
# or without it.
CONFIG=${BR2_CONFIG:-}
[ -n "$CONFIG" ] || CONFIG=${O:-$(dirname -- "$TARGET")}/.config

say()  { echo "the image and the packages: $*"; }
die()  { echo "the image and the packages: $*" >&2; exit 1; }

[ -f "$CONFIG" ] || die "no Buildroot .config at $CONFIG; nothing to check against"
[ -d "$PKGDIR" ] || die "no package directory at $PKGDIR"

# ---------------------------------------------------------------- the packages
#
# What each enabled package installs into the target, read from the tree:
#
#   usr/bin/<p>         for every word of `PROGRAMS :=` in <pkg>/src/Makefile,
#                       which is the list its `install` rule copies there
#   etc/init.d/<S..>    for every S-numbered file beside <pkg>/<pkg>.mk, which
#                       is what its INSTALL_INIT_SYSV copies there
#
# Both are what the package's own rules use, so the derivation cannot drift
# from the build without check 2 failing.

expected=
declared=
packages=0

for pkg in "$PKGDIR"/*/; do
	name=$(basename -- "$pkg")
	[ -f "$pkg/Config.in" ] || die "$name has no Config.in"

	sym=$(sed -n 's/^config \(BR2_PACKAGE_[A-Z0-9_]*\)[[:space:]]*$/\1/p' "$pkg/Config.in" | head -1)
	[ -n "$sym" ] || die "$name/Config.in declares no BR2_PACKAGE_ symbol"
	declared="$declared $sym"

	# check 3a: kconfig has seen it, so boards/arty-z7-20/linux/buildroot/Config.in sources it
	grep -qE "^($sym=|# $sym is not set)" "$CONFIG" \
		|| die "$name declares $sym and the built .config has never heard of it:
    boards/arty-z7-20/linux/buildroot/Config.in does not source $name/Config.in, so the package
    is not in the image at all.  Add the source line."

	grep -qx "$sym=y" "$CONFIG" || continue
	packages=$((packages + 1))

	if [ -f "$pkg/src/Makefile" ]; then
		for p in $(sed -n 's/^PROGRAMS[[:space:]]*:*=[[:space:]]*//p' "$pkg/src/Makefile"); do
			expected="$expected usr/bin/$p"
		done
	fi
	for s in "$pkg"S[0-9][0-9]*; do
		[ -f "$s" ] || continue
		expected="$expected etc/init.d/$(basename -- "$s")"
	done
done

[ "$packages" -gt 0 ] || die "no package under $PKGDIR is enabled; the check would be vacuous"

# check 3b: no defconfig turns on a symbol no package declares any more
for dc in "$EXT"/configs/*_defconfig; do
	[ -f "$dc" ] || continue
	for sym in $(sed -n 's/^\(BR2_PACKAGE_CADR_[A-Z0-9_]*\)=y$/\1/p' "$dc"); do
		case " $declared " in
			*" $sym "*) ;;
			*) die "$(basename -- "$dc") sets $sym=y and no package declares it:
    a rename moved the package and left the defconfig behind, so the program
    is silently NOT in the image.  Fix the defconfig." ;;
		esac
	done
done

# ------------------------------------------------------------------ the target

# check 2: everything the packages install is there
for path in $expected; do
	[ -f "$TARGET/$path" ] \
		|| die "a package installs $path and the image has no such file:
    the package built and did not install, or the name this check derived from
    the tree is not the name the package uses.  Either way the image is not
    what was asked for."
done

# check 1: nothing else of ours is there
stale=
for path in $(cd "$TARGET" && find . \( -type f -o -type l \) -name '*cadr*' | sed 's|^\./||' | LC_ALL=C sort); do
	case " $expected " in
		*" $path "*) ;;
		*) stale="$stale $path" ;;
	esac
done

if [ -n "$stale" ]; then
	echo "the image and the packages: THE IMAGE HOLDS A PROGRAM NO PACKAGE INSTALLS." >&2
	echo >&2
	for path in $stale; do
		echo "    $TARGET/$path" >&2
	done
	echo >&2
	echo "Buildroot builds output/target/ up and never removes what a package" >&2
	echo "stopped installing, so a renamed or deleted package leaves its old" >&2
	echo "files behind and the image ships BOTH.  Two disk pack programs ran on" >&2
	echo "the board that way, each writing blocks back to the same pack, and it" >&2
	echo "corrupted the pack.  Delete them and build again:" >&2
	echo >&2
	for path in $stale; do
		echo "    rm -f $TARGET/$path" >&2
	done
	echo >&2
	echo "If one of them is a program a package DOES install, this check derived" >&2
	echo "the wrong name from the tree and the check is what needs fixing." >&2
	exit 1
fi

say "$packages package(s), $(echo $expected | wc -w) installed file(s), no leftovers"
