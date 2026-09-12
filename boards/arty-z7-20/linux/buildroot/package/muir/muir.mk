# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# muir on the board, built and not vendored.
#
# Every other package here is one of our own C programs built by Buildroot's
# `local` site method out of the src/ directory beside its .mk.  This one is
# different in both halves: the source is upstream muir's, and it is Rust, so
# it uses Buildroot's own Cargo infrastructure --- `$(eval $(cargo-package))`
# --- which is what Buildroot's manual prescribes for a crate.
#
# **THE VERSION IS READ FROM muir.commit AND IS NOT WRITTEN HERE.**  That file
# is what says which muir this repository is held to; every reference trace in
# golden/ is that muir's behaviour written down.  A SHA typed into this file
# would be a second place to change, and the two would part company on the
# first bump that forgot one.  So the pin is read, and moving the pin moves
# the board's muir with no edit here.
#
# **AND THE PIN MOVING NEEDS NO `-reconfigure` EITHER**, which is why muir is
# absent from the Makefile's `buildroot-rebuild` list where every other package
# of ours is named.  Those are built from files Buildroot does not watch, so a
# change to them needs the package forced.  Here the pin IS the version, so a
# new pin is a new $(BUILD_DIR)/muir-<sha>/ and Buildroot rebuilds of its own
# accord.
#
# **THE SOURCE COMES FROM muir'S OWN GIT** rather than from ../../muir beside
# this repository.  A local path would rsync whatever is checked out there,
# which is a working tree somebody may be mid-slice in --- CLAUDE.md's rule is
# that it must not be moved for exactly that reason --- and the image would
# then hold a muir that is no commit.  Buildroot clones the commit and makes a
# tarball of it in $(DL_DIR), so a rebuild fetches nothing and a build is
# reproducible from the pin alone.
#
# **THERE IS NO .hash FILE, AND THAT IS A CHOICE.**  A hash covers the tarball
# Buildroot builds from the clone, so it would have to be recomputed every time
# muir.commit moves --- reintroducing the second place to change that the pin
# exists to remove.  The commit itself is the integrity claim: a 40-character
# SHA names one tree and nothing else.  support/download/check-hash exits 0
# with a warning when a package has no hash file at all, so `make buildroot`
# prints one line about it and carries on; BR2_DOWNLOAD_FORCE_CHECK_HASHES only
# governs the case where a hash file exists and has no line for the file.
#
# **WHAT `muir --version` SAYS, AND WHY IT NEEDS HELP.**  muir's build.rs asks
# git for the commit it was built from and stamps it in for --version and for
# the first line of every run.  Buildroot builds from an extracted tarball with
# no .git in it, so build.rs finds nothing and says nothing, and the board's
# muir would call itself `muir 0.1.0-release` --- true, and useless for saying
# which muir is running.  build.rs emits no MUIR_GIT in that case and
# src/main.rs reads it with option_env!, which takes the value from the
# compile-time environment, so handing cargo the abbreviated pin puts it back.
# The board then says `muir 0.1.0-<pin>-release`, which is the pin.
#
# **ONLY THE muir BINARY IS INSTALLED.**  The crate also builds src/bin/
# diskpack.rs, and cargo-package's own install step is `cargo install --bins`,
# which would put both in /usr/bin.  A second program nobody asked for is a
# second program on the board, so the install is written out here instead: it
# names the one binary, and naming it is also what lets board/arty-z7-20/
# post-build.sh derive from this file that /usr/bin/muir must be in the image.
#
# **NO INIT SCRIPT.**  Decided with Mete on 12 September: muir is started by
# hand when it is wanted.  Config.in has the argument.
#
# **THE COMPILER IS NOT THE ONE muir PINS, AND THAT IS A DECISION SOMEBODY
# SHOULD TAKE RATHER THAN INHERIT.**  Measured on 12 September at this
# Buildroot:
#
#     Buildroot 2026.02.3's host-rust-bin   rustc 1.88.0 (6b00bc388 2025-06-23)
#     muir's rust-toolchain.toml            1.99.0-beta.4
#     this repository's rust-toolchain.toml 1.99.0-beta.4, tracking muir's
#
# muir pins a beta for a reason it writes down: 1.98.0 and 1.98.1 miscompile
# chaos::board::Turn::tc at opt-level 3 with codegen-units 1, producing a byte
# the function's own arithmetic cannot reach.  rust-toolchain.toml is rustup's
# file and Buildroot's cargo is the real binary rather than a rustup shim, so
# the pin is ignored here --- which is also why nothing tries to fetch a beta
# during the build.
#
# **The known miscompile is dodged, and by Buildroot rather than by us.**  Its
# PKG_CARGO_ENV overrides muir's own [profile.release] wholesale, and the build
# line records what it used: CARGO_PROFILE_RELEASE_OPT_LEVEL="2",
# CARGO_PROFILE_RELEASE_CODEGEN_UNITS="16", CARGO_PROFILE_RELEASE_LTO="false".
# The configuration the bug needs is opt-level 3 with codegen-units 1, and
# muir's own note says codegen-units 16 "is also correct".  So the board is out
# of the bug's window twice over.
#
# **What is NOT established is anything stronger than that.**  No muir test has
# been run against a 1.88 build, here or anywhere, so the board runs a muir
# compiled by a compiler this project has not tested.  Three ways out, none
# taken here because it is not a package's decision: run muir's own suite under
# 1.88 on the host and record it; wait for 1.99 to ship, which is the one edit
# muir's pin file says it is waiting for, and for Buildroot to carry it; or
# build muir on the host with the pinned toolchain and have the package install
# that, which trades the compiler question for a build that is no longer
# reproducible from this tree alone.

MUIR_COMMIT_FILE = $(BR2_EXTERNAL_CADR_PATH)/../../../../muir.commit
# `:=` and not `=`: Buildroot expands a package's VERSION dozens of times, and
# a recursive assignment would run the sed at every one of them.
MUIR_VERSION := $(shell sed -n 's/^\([0-9a-f]\{40\}\)$$/\1/p' $(MUIR_COMMIT_FILE))
MUIR_SITE = https://github.com/metebalci/muir.git
MUIR_SITE_METHOD = git
MUIR_LICENSE = AGPL-3.0-or-later
MUIR_LICENSE_FILES = LICENSE
# Buildroot's Cargo infrastructure appends ", vendored dependencies licenses
# probably not listed" to every crate's licence, because a crate usually
# vendors some.  muir vendors none --- its [dependencies] section is empty and
# Cargo.lock names one package, itself --- so that clause is true of nothing
# here.  It is Buildroot's line and not ours, and it shows only in
# `make legal-info`, which nothing in this project runs.

# The abbreviated commit in the form build.rs would have stamped: `git
# rev-parse --short HEAD` gives seven characters on a repository this size, and
# a version line that does not match the one a developer's own build prints is
# a version line somebody has to think about.
MUIR_GIT_SHORT := $(shell echo $(MUIR_VERSION) | cut -c1-7)
MUIR_CARGO_ENV = MUIR_GIT=$(MUIR_GIT_SHORT)

ifeq ($(BR2_PACKAGE_MUIR),y)
ifeq ($(MUIR_VERSION),)
$(error muir: no 40-character commit on a line of its own in $(MUIR_COMMIT_FILE); \
	that file is the pin and the package has nothing to build without it)
endif
endif

define MUIR_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/target/$(RUSTC_TARGET_NAME)/release/muir \
		$(TARGET_DIR)/usr/bin/muir
	$(INSTALL) -d -m 0755 $(TARGET_DIR)/root
	ln -sf /mnt/packs/muirrc $(TARGET_DIR)/root/.muirrc
endef

$(eval $(cargo-package))
