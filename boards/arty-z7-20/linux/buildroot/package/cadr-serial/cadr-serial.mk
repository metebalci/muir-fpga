# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The serial line, one program per package as cadr-disk-packs' Config.in said
# in September each of them would be --- "the console, the RFB server, the
# Chaosnet bridge and USB input each get their own beside this one".  This is
# the serial line.  Buildroot's `local` site method builds straight from the
# src/ directory beside this file --- no tarball, no version, no hash --- and
# `make buildroot-rebuild` at the repository root is what makes Buildroot
# notice a change here.
#
# What is in it:
#
#   cadr-serial       maps the 2651's register face on M_AXI_GP0 and offers
#                     the far end of the RS-232 cable at J9 on a TCP socket,
#                     as muir's `--serial <endpoint>` does.
#                     src/cadr-serial.c's header says how, and
#                     src/serial_face.h is the register face with what it
#                     assumed about the fabric written on it
#   S86cadr-serial    starts it at boot, its log on the console
#
# **AND AN INIT SCRIPT, WHERE cadr-console HAS NONE.**  The console is a
# person at a prompt and started at boot would hold a second master on the
# diagnostic bus all day.  This one is a daemon, for cadr-terminal's reason:
# what it holds while nobody is attached is a listening socket and a poll of
# eight words, and it is there the moment somebody wants the line.  S86, after
# S85cadr-terminal and S80cadr-disk-packs, so that the console log reads in
# the order a person reading it wants --- the drive, the screen, then the
# serial line.
#
# The shared transport --- /dev/mem, the EMIO tally guard, the logging --- is
# cadr-common's, a static library in the staging tree.  Not a relative include
# of the sibling package's src/: `local` rsyncs only THIS package's src/ into
# the build directory.  package/cadr-common/cadr-common.mk's header has the
# argument in full.
#
# And `make -C src check` on the build host, which needs nothing but a C
# compiler and python3: the endpoint driven against a model of the 2651's far
# side, with a client written for the purpose on a loopback socket, and then
# every record in src/serial_mutations.txt, each of which the check must fail
# on.

CADR_SERIAL_VERSION = 0
CADR_SERIAL_SITE = $(BR2_EXTERNAL_CADR_PATH)/package/cadr-serial/src
CADR_SERIAL_SITE_METHOD = local
CADR_SERIAL_LICENSE = AGPL-3.0-or-later
CADR_SERIAL_DEPENDENCIES = cadr-common

define CADR_SERIAL_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)
endef

define CADR_SERIAL_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
endef

define CADR_SERIAL_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(CADR_SERIAL_PKGDIR)/S86cadr-serial \
		$(TARGET_DIR)/etc/init.d/S86cadr-serial
endef

$(eval $(generic-package))
