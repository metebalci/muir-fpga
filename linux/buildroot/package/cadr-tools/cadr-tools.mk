# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Our own programs on the processing system.  Buildroot's `local` site
# method builds straight from the src/ directory beside this file --- no
# tarball, no version, no hash --- so a program is a C file and a line in
# src/Makefile.  `make buildroot-rebuild` at the repository root is what
# makes Buildroot notice a change here.
#
# What is in it:
#
#   cadr-pack-feeder      serves the CADR's disk from the pack file on the
#                         card, on demand: the controller posts the block
#                         it lacks and this fetches it into the store, and
#                         takes written blocks back; src/cadr-pack-feeder.c's
#                         header says how
#   S80cadr-pack-feeder   mounts the card at /mnt/card and starts the feeder
#                         at boot, its log on the console
#
# And `make -C src check` on the build host, which needs nothing but a C
# compiler and build/disk.golden: the feeder's core against a model of the
# register face with a scripted controller behind it that asks for the
# reference trace's blocks and more.

CADR_TOOLS_VERSION = 0
CADR_TOOLS_SITE = $(BR2_EXTERNAL_CADR_PATH)/package/cadr-tools/src
CADR_TOOLS_SITE_METHOD = local
CADR_TOOLS_LICENSE = AGPL-3.0-or-later

define CADR_TOOLS_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)
endef

define CADR_TOOLS_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
endef

define CADR_TOOLS_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(CADR_TOOLS_PKGDIR)/S80cadr-pack-feeder \
		$(TARGET_DIR)/etc/init.d/S80cadr-pack-feeder
endef

$(eval $(generic-package))
