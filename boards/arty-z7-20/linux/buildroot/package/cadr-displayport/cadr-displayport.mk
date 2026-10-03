# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The Kria KR260's DisplayPort link, one program, as the board's display
# output needs it: src/dp_link.h is the account.
#
#   cadr-displayport        brings the link up, keeps it, and follows the
#                           display output's sleep (console word 36)
#   S83cadr-displayport     starts it at boot, its log on the console
#
# Built only for the Kria KR260 (Config.in depends on its address map), and
# from src/ by the `local` site method, as every package here.  `make -C src
# check` on the build host runs the link's procedure against a model of the
# board and every record of src/displayport_mutations.txt.
#
# **TWO LICENSES.**  The program is this project's, AGPL-3.0-or-later;
# src/amd_dp_tables.h carries two tables of AMD's under the MIT License,
# whose text is src/AMD-Xilinx-MIT.txt.

CADR_DISPLAYPORT_VERSION = 0
CADR_DISPLAYPORT_SITE = $(BR2_EXTERNAL_CADR_PATH)/package/cadr-displayport/src
CADR_DISPLAYPORT_SITE_METHOD = local
CADR_DISPLAYPORT_LICENSE = AGPL-3.0-or-later, MIT (amd_dp_tables.h)
CADR_DISPLAYPORT_LICENSE_FILES = AMD-Xilinx-MIT.txt
CADR_DISPLAYPORT_DEPENDENCIES = cadr-common

define CADR_DISPLAYPORT_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)
endef

define CADR_DISPLAYPORT_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
endef

define CADR_DISPLAYPORT_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(CADR_DISPLAYPORT_PKGDIR)/S83cadr-displayport \
		$(TARGET_DIR)/etc/init.d/S83cadr-displayport
endef

$(eval $(generic-package))
