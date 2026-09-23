# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What our programs on the processing system share below the fabric: the
# /dev/mem mapping, the EMIO tally guard that must run before ANY access to
# a GP port, the logging one line at a time, and the local input link --- the
# socket a program with a keyboard on it sends keys along to the one program
# that writes the keyboard's registers.  That last one is here for a second
# reason as well as sharing: it is a WIRE FORMAT, and a wire format with two
# definitions is two formats.  It arrived when the second
# program did, which is what cadr-disk-pack/Config.in said in September would
# happen: "what they share goes into a cadr-common package when the second
# arrives".  The second is cadr-console.
#
# **WHY A STATIC LIBRARY IN THE STAGING TREE AND NOT A HEADER OF `static
# inline`s.**  Buildroot's `local` site method rsyncs only the package's own
# src/ into the build directory, so a sibling package's files are not there
# when the target build runs and a relative `../cadr-common/src/...` include
# builds on the host and fails under Buildroot.  Two shapes get around that:
# a library in staging, or a header copied into each consumer's src/ by a
# _PRE_BUILD_HOOK the way boards/arty-z7-20/linux/buildroot/external.mk copies the reserved
# dtsi and U-Boot's environment.  This is the library, for one reason that is
# about the code and not about taste: `say()` writes to one destination a
# program chooses once --- `--log /dev/console` for the init script --- and
# that destination is a file-static.  As a `static inline` in a header it
# would be a separate file-static in every translation unit that included it,
# so a program of two source files would have two log destinations and
# `cadr_log_to()` in one of them would move only its own.  A library has one
# definition and cannot do that.  `pack_ecc.h` is header-only for the
# opposite reason: it is arithmetic and holds no state.
#
# **AND ONE FILE DOES GO ON THE TARGET, and it is not C.**  `fpgarc.sh` is the
# shell reader that every init script hands the card's `fpgarc` to: the file
# is one for the whole fabric station and the programs reading it are several,
# each of them strict about a flag it does not know, so each init script names
# the flags its own program owns and is given those lines and no others.  One
# reader, installed at /usr/share/cadr/fpgarc.sh, because a format read by
# five scripts and written by one card script is a format with one definition
# or it is several.  Its own header is the contract and docs/fpgarc.md has the
# lists.
#
# So: the library and the headers go to staging, the reader goes on the
# target, and a consumer sets `CADR_XXX_DEPENDENCIES = cadr-common`, includes
# <cadr/cadr_mem.h> and links -lcadr-common.  $(TARGET_CONFIGURE_OPTS)
# already carries --sysroot=$(STAGING_DIR), so no -I or -L is needed.
#
# The host build (`make -C src check` in a consumer) does not use this at
# all: there `..` is a real directory and the consumer compiles these .c
# files straight from it.  Each consumer's src/Makefile says which of its two
# source lists is for which build.

CADR_COMMON_VERSION = 0
CADR_COMMON_SITE = $(BR2_EXTERNAL_CADR_PATH)/package/cadr-common/src
CADR_COMMON_SITE_METHOD = local
CADR_COMMON_LICENSE = AGPL-3.0-or-later
CADR_COMMON_INSTALL_STAGING = YES
CADR_COMMON_INSTALL_TARGET = YES

# **THE BOARD'S ADDRESS MAP**, from the one choice in Config.in, handed to
# both the build and the staging install from this one variable, so the
# library and the header every program includes cannot be for two boards.
# src/Makefile says how the header carries it.
ifeq ($(BR2_CADR_BOARD_DE25_NANO),y)
CADR_COMMON_BOARD = de25-nano
else
CADR_COMMON_BOARD = zynq-7000
endif

define CADR_COMMON_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D) \
		CADR_BOARD=$(CADR_COMMON_BOARD)
endef

define CADR_COMMON_INSTALL_STAGING_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(STAGING_DIR) \
		CADR_BOARD=$(CADR_COMMON_BOARD) install-staging
endef

define CADR_COMMON_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) \
		CADR_BOARD=$(CADR_COMMON_BOARD) install
endef

$(eval $(generic-package))
