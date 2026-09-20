# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# ozd on the board, built and not vendored.
#
# This is muir's package with one program changed, and the reasons it gives
# hold here word for word: the source is upstream ozd's, it is Rust, so it uses
# Buildroot's own Cargo infrastructure --- `$(eval $(cargo-package))`, which is
# what Buildroot's manual prescribes for a crate.  The version is read from
# `ozd.commit` and is not written here, the source comes from ozd's own git
# rather than from a working tree beside this one, and there is no `.hash`
# file, because the commit itself is the integrity claim.
#
# **THE COMPILER IS NOT THE ONE ozd PINS, AND THIS TIME THE QUESTION IS
# CLOSED.**  muir's package states the same mismatch and leaves it open,
# because no muir test had been run against Buildroot's compiler.  Measured
# here on 20 September:
#
#     Buildroot 2026.02.3's host-rust-bin   rustc 1.88.0 (6b00bc388 2025-06-23)
#     ozd's rust-toolchain.toml             1.98.0, a stable channel
#
# `rust-toolchain.toml` is rustup's file and Buildroot's cargo is the real
# binary rather than a rustup shim, so the pin is ignored here --- which is
# also why nothing tries to fetch a toolchain during the build.  ozd's own
# suite was then run under Buildroot's own 1.88.0 on the build host: 230 tests,
# all passing, none ignored.  ozd carries no crate dependencies, no build
# script and no C, so there is nothing else in the build for a compiler to
# differ about.  Re-run that suite whenever either version moves; it is a few
# seconds, because ozd has nothing to compile but itself.
#
# **AND THERE IS NO SEPARATE STATIC BUILD, WHICH WAS THE OTHER ROUTE.**
# Building ozd outside Buildroot against a musl target and installing the
# binary would honor ozd's pin exactly, and it would cost two things: a
# prebuilt binary that the image no longer builds from source, and a rustup
# toolchain with two musl targets that somebody has to install and keep.  It
# would buy nothing here, because the host Rust compiler is ALREADY in every
# one of this project's three defconfigs --- muir selects it --- and the target
# standard library for each board's triple is already in each board's host
# tree.  Cross-building ozd with them takes under three seconds a board.  So
# the cheaper route is the one Buildroot already pays for.
#
# **ONLY THE ozd BINARY IS INSTALLED.**  The crate also builds `examples/ask`,
# which cargo-package's `cargo install --bins` would leave out in any case, and
# naming the one binary here is also what lets a post-build check derive from
# this file that /usr/bin/ozd must be in the image.
#
# **THE INIT SCRIPT IS S84**, which is after S80cadr-disk-packs, because it
# reads the card's file of flags and that script is the one thing that mounts
# the partition the file is on, and before S87cadr-chaosnet, because the
# machine's first request for the time should find a host already listening.
# It is not last, so S88cadr-usb-input keeps the report of the lines no program
# claimed.
#
# **AND ozd RUNS AS A USER OF ITS OWN.**  It refuses to run as root, in its own
# words, and it is right to: nothing it does needs a privilege, and as root a
# path check it got wrong would reach the whole filesystem.  Buildroot's users
# table makes the user and its home directory; the init script starts the
# program under it.

OZD_COMMIT_FILE = $(BR2_EXTERNAL_CADR_PATH)/../../../../ozd.commit
# `:=` and not `=`, for muir's reason: Buildroot expands a package's VERSION
# dozens of times and a recursive assignment would run the sed at every one.
OZD_VERSION := $(shell sed -n 's/^\([0-9a-f]\{40\}\)$$/\1/p' $(OZD_COMMIT_FILE))
OZD_SITE = https://github.com/metebalci/ozd.git
OZD_SITE_METHOD = git
OZD_LICENSE = AGPL-3.0-or-later
OZD_LICENSE_FILES = LICENSE

ifeq ($(BR2_PACKAGE_OZD),y)
ifeq ($(OZD_VERSION),)
$(error ozd: no 40-character commit on a line of its own in $(OZD_COMMIT_FILE); \
	that file is the pin and the package has nothing to build without it)
endif
endif

define OZD_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/target/$(RUSTC_TARGET_NAME)/release/ozd \
		$(TARGET_DIR)/usr/bin/ozd
endef

define OZD_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(OZD_PKGDIR)/S84ozd \
		$(TARGET_DIR)/etc/init.d/S84ozd
endef

$(eval $(cargo-package))
