# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX's Ethernet device, one program per package as the others are.
# Buildroot's `local` site method builds straight from the src/ directory
# beside this file, linking cadr-common's library from staging.  Its init
# script makes the tap quux0 and starts it only on a card that says
# `--machine quux`.

QUUX_ETHERNET_DEVICE_VERSION = 0
QUUX_ETHERNET_DEVICE_SITE = $(BR2_EXTERNAL_CADR_PATH)/package/quux-ethernet-device/src
QUUX_ETHERNET_DEVICE_SITE_METHOD = local
QUUX_ETHERNET_DEVICE_LICENSE = AGPL-3.0-or-later
QUUX_ETHERNET_DEVICE_DEPENDENCIES = cadr-common

define QUUX_ETHERNET_DEVICE_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)
endef

define QUUX_ETHERNET_DEVICE_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
endef

define QUUX_ETHERNET_DEVICE_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(QUUX_ETHERNET_DEVICE_PKGDIR)/S82quux-ethernet-device \
		$(TARGET_DIR)/etc/init.d/S82quux-ethernet-device
endef

$(eval $(generic-package))
