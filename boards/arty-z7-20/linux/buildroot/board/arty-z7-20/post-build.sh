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
# channel for a day.  The channel was innocent.
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
#      built `.config` unless its own `depends on` is unmet there, and every
#      `BR2_PACKAGE_CADR_*=y` in a defconfig must be a symbol some package
#      declares.  A half-done rename --- the directory
#      moved and Config.in or the defconfig not --- silently drops the package
#      from the image, and then checks 1 and 2 agree about a smaller machine
#      than the one that was asked for.
#
# **What it does not reach.**  A ghost whose name is in neither namespace check
# 1 looks at --- a program of ours renamed out of `cadr`, or a stale file from
# an upstream Buildroot package --- is invisible to it, because nothing in
# Buildroot records what an upstream package installed in a way that survives
# the package going away (see the paragraph above).  Check 2 still catches our
# own side of that: the new name is expected and missing.  Say so rather than
# claim more.
#
# **A program's settings file is covered only where it is a symlink the .mk
# names.**  /root/.cadrrc and /root/.quuxrc are symlinks the muir package
# installs, onto files on the card, and the derivation reads them from its
# `ln -sf` lines: check 2 asks that each is there as a link, since what it
# points at is on the card and not in the image, and check 1 names one that
# no package makes, `.cadrrc` being in the `cadr` family below.

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

# The `depends on` expressions of the `config <sym>` entry in <Config.in>,
# one a line (Kconfig ANDs them): the lines after `config <sym>` up to the
# next entry (config, menuconfig, comment, menu, choice, if, source, end*) or
# the entry's help, so neither a `comment`'s own `depends on` nor the words of
# a help text are taken for the package's.
depends_of() {
	awk -v sym="$2" '
		$1 == "config" && $2 == sym { on = 1; next }
		on && $1 ~ /^(config|menuconfig|comment|menu|choice|if|source|end[a-z]*|help|---help---)$/ { exit }
		on && $1 == "depends" && $2 == "on" { sub(/^[ \t]*depends[ \t]+on[ \t]+/, ""); print }
	' "$1"
}
# Whether a `depends on` expression holds in $CONFIG.  Only what the packages
# here write is understood: symbols, `!symbol`, joined by `&&`.  Anything else
# (`||`, parentheses, comparisons) stops the build rather than be guessed at.
depends_met() {
	for term in $(echo "$1" | sed 's/&&/ /g'); do
		case $term in
			!BR2_[A-Z0-9_]*) ! grep -qx "${term#!}=y" "$CONFIG" || return 1 ;;
			BR2_[A-Z0-9_]*)  grep -qx "$term=y" "$CONFIG" || return 1 ;;
			*) die "a dependency term this check cannot evaluate: '$term' in '$1'" ;;
		esac
	done
	return 0
}

[ -f "$CONFIG" ] || die "no Buildroot .config at $CONFIG; nothing to check against"
[ -d "$PKGDIR" ] || die "no package directory at $PKGDIR"

# ---------------------------------------------------------------- the packages
#
# What each enabled package installs into the target, read from the tree:
#
#   usr/bin/<p>         for every word of `PROGRAMS :=` in <pkg>/src/Makefile,
#                       which is the list its `install` rule copies there
#   usr/bin/<p>         for a package with no src/Makefile of ours, every
#                       $(TARGET_DIR)/usr/bin/<p> its own .mk names --- which
#                       is how muir, built from upstream source, states what it
#                       installs
#   root/<rc>           and every symlink such a .mk makes into root's home,
#                       `ln -sf <card path> $(TARGET_DIR)/root/<rc>`: muir's
#                       `.cadrrc` and `.quuxrc`
#   etc/init.d/<S..>    for every S-numbered file beside <pkg>/<pkg>.mk, which
#                       is what its INSTALL_INIT_SYSV copies there
#
# All three are what the package's own rules use, so the derivation cannot
# drift from the build without check 2 failing.

expected=
declared=
packages=0

for pkg in "$PKGDIR"/*/; do
	name=$(basename -- "$pkg")
	[ -f "$pkg/Config.in" ] || die "$name has no Config.in"

	sym=$(sed -n 's/^config \(BR2_PACKAGE_[A-Z0-9_]*\)[[:space:]]*$/\1/p' "$pkg/Config.in" | head -1)
	[ -n "$sym" ] || die "$name/Config.in declares no BR2_PACKAGE_ symbol"
	declared="$declared $sym"

	# check 3a: kconfig has seen it, so boards/arty-z7-20/linux/buildroot/Config.in sources it.
	# Kconfig writes no line at all for a symbol whose `depends on` is unmet,
	# so such a symbol's absence says nothing about the source line: the
	# Kria KR260's cadr-displayport on every other board.  Its absence is
	# accepted only when its dependency is evaluated and found unmet here.
	if ! grep -qE "^($sym=|# $sym is not set)" "$CONFIG"; then
		deps=$(depends_of "$pkg/Config.in" "$sym")
		if [ -n "$deps" ] && ! depends_met "$deps"; then
			say "$name is not on this board: $sym depends on" $deps
			continue
		fi
		die "$name declares $sym and the built .config has never heard of it:
    boards/arty-z7-20/linux/buildroot/Config.in does not source $name/Config.in, so the package
    is not in the image at all.  Add the source line."
	fi

	grep -qx "$sym=y" "$CONFIG" || continue
	packages=$((packages + 1))

	if [ -f "$pkg/src/Makefile" ]; then
		for p in $(sed -n 's/^PROGRAMS[[:space:]]*:*=[[:space:]]*//p' "$pkg/src/Makefile"); do
			expected="$expected usr/bin/$p"
		done
	else
		# A package with no src/ of ours --- one built from upstream
		# source, as muir is --- states what it installs in its own
		# .mk, so the derivation still comes from the source tree and
		# not from anything Buildroot wrote.
		for p in $(sed -n 's|.*$(TARGET_DIR)/usr/bin/\([A-Za-z0-9._-]*\).*|\1|p' "$pkg/$name.mk"); do
			expected="$expected usr/bin/$p"
		done
		# And the settings files it links into root's home: muir's
		# `.cadrrc` and `.quuxrc`, each a symlink onto the card.
		for p in $(sed -n 's|^[[:space:]]*ln -sf [^ ]* $(TARGET_DIR)/root/\([A-Za-z0-9._-]*\)$|\1|p' "$pkg/$name.mk"); do
			expected="$expected root/$p"
		done
	fi
	for s in "$pkg"S[0-9][0-9]*; do
		[ -f "$s" ] || continue
		expected="$expected etc/init.d/$(basename -- "$s")"
	done
done

[ "$packages" -gt 0 ] || die "no package under $PKGDIR is enabled; the check would be vacuous"

# check 3b: no defconfig turns on a symbol no package declares any more.
#
# It has to know which symbols are this tree's, because a defconfig is full of
# upstream Buildroot ones that no package here declares and must not.  There is
# no way to tell the two apart from inside this script --- Buildroot's own
# source is not reachable from here --- so the namespaces are enumerated:
# BR2_PACKAGE_CADR_* for our own programs, and BR2_PACKAGE_MUIR and
# BR2_PACKAGE_OZD, which are outside that namespace because neither is one of
# our programs: they are muir (its `cadr` and `quux`) and ozd, carried rather
# than written here.
# Anything added in a further namespace wants a further expression.
for dc in "$EXT"/configs/*_defconfig; do
	[ -f "$dc" ] || continue
	for sym in $(sed -n \
			-e 's/^\(BR2_PACKAGE_CADR_[A-Z0-9_]*\)=y$/\1/p' \
			-e 's/^\(BR2_PACKAGE_MUIR\)=y$/\1/p' \
			-e 's/^\(BR2_PACKAGE_OZD\)=y$/\1/p' "$dc"); do
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
	[ -f "$TARGET/$path" ] || [ -L "$TARGET/$path" ] \
		|| die "a package installs $path and the image has no such file:
    the package built and did not install, or the name this check derived from
    the tree is not the name the package uses.  Either way the image is not
    what was asked for."
done

# check 1: nothing else of ours is there.
#
# The names it looks at are the same namespaces check 3b enumerates, and for
# the same reason: a find over every file in the target would flag every
# BusyBox applet.  `quux`, `muir` and `ozd` are matched exactly --- each is
# one program, not a family, and `cadr` is in the family above --- so that the
# day a package is renamed or dropped, the program it leaves behind is caught
# rather than shipped.  `muir` stays although no package installs it since
# muir became `cadr` and `quux`: an image built over an old target would carry
# the old /usr/bin/muir, and this names it.
stale=
for path in $(cd "$TARGET" && find . \( -type f -o -type l \) \( -name '*cadr*' -o -name 'quux' -o -name 'muir' -o -name 'ozd' \) | sed 's|^\./||' | LC_ALL=C sort); do
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

# **AND NOTHING IN THE IMAGE NAMES THE MACHINE IT WAS BUILT ON.**  The image
# is published, and a path under the build directory or the builder's home
# names the builder.  Two things carried one: the external toolchain's
# libstdc++ pretty-printer for gdb (usr/lib/libstdc++.so.*-gdb.py), which
# writes the toolchain's absolute paths into the target and which no program
# here reads, so it is removed; and a Rust program's own source paths, which
# ozd.mk now remaps.  Then the whole target is searched for the build
# directory and the home directory, and the kernel's own record of who built
# it (include/generated/compile.h, which the version string carries) must say
# buildroot, which external.mk sets.  A finding stops the build.
rm -f "$TARGET"/usr/lib/libstdc++.so.*-gdb.py
# The home directory only when it is a user's under /home: /root is a path the
# image itself uses, and a builder working as root is named by BASE_DIR.
case "${HOME:-}" in /home/?*) home=$HOME ;; *) home= ;; esac
for leak in "${BASE_DIR:-}" "$home"; do
	[ -n "$leak" ] && [ "$leak" != / ] || continue
	found=$(grep -rlF -- "$leak" "$TARGET" 2>/dev/null | sed "s|^$TARGET/||" || true)
	if [ -n "$found" ]; then
		echo "the image and the packages: THE IMAGE NAMES THE BUILD HOST: $leak is in" >&2
		echo "$found" | sed 's/^/    /' >&2
		exit 1
	fi
done
for compile_h in "${BUILD_DIR:-/nonexistent}"/linux-*/include/generated/compile.h; do
	[ -f "$compile_h" ] || continue
	by=$(sed -n 's/^#define LINUX_COMPILE_BY[[:space:]]*"\(.*\)"$/\1/p' "$compile_h")
	host=$(sed -n 's/^#define LINUX_COMPILE_HOST[[:space:]]*"\(.*\)"$/\1/p' "$compile_h")
	[ "$by@$host" = buildroot@buildroot ] \
		|| die "the kernel says it was built by $by@$host, not buildroot@buildroot ($compile_h)"
	say "the kernel was built by $by@$host"
done
say "no path of the build host in the image"
