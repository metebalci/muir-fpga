# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The skeleton of our own programs on the processing system.  Buildroot's
# `local` site method builds straight from the src/ directory beside this
# file --- no tarball, no version, no hash --- so the next slice adds a C
# file and a line to src/Makefile and has it on the board.  The one program
# in it today does nothing but say what it is, so that the mechanism is
# exercised before anything depends on it.

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

$(eval $(generic-package))
