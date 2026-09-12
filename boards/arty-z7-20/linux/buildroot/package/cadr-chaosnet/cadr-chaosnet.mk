# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The Chaosnet program: one package per program, which is this project's rule
# since 10 September.  CLAUDE.md names it as "routing and its services", and
# what it routes between is the Chaosnet interface in the fabric and the
# board's gigabit Ethernet.
#
# **AND AN INIT SCRIPT.**  The argument is cadr-terminal's: what it holds
# while nothing is happening is a mapping and a socket, so it costs a process,
# and it is there when the machine wants it.  A cable that has to be plugged
# in by hand is a cable the band finds missing at exactly the moment it looks.
# S87, after S86cadr-serial, so the console log reads in the order a person
# reading it wants: the drive, the screen, the serial line, then the network.
#
# The shared transport --- /dev/mem, the EMIO tally guard, the logging --- is
# cadr-common's, a static library in the staging tree.  Not a relative include
# of the sibling package's src/: `local` rsyncs only THIS package's src/ into
# the build directory.  package/cadr-common/cadr-common.mk's header has the
# argument in full.
#
# And `make -C src check` on the build host, which needs nothing but a C
# compiler and python3: the packet and its check word, CHUDP on a loopback
# socket, and the register face against a model of the RTL --- then every
# record in src/chaos_mutations.txt, each of which the check must fail on.

CADR_CHAOSNET_VERSION = 0
CADR_CHAOSNET_SITE = $(BR2_EXTERNAL_CADR_PATH)/package/cadr-chaosnet/src
CADR_CHAOSNET_SITE_METHOD = local
CADR_CHAOSNET_LICENSE = AGPL-3.0-or-later
CADR_CHAOSNET_DEPENDENCIES = cadr-common

define CADR_CHAOSNET_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)
endef

define CADR_CHAOSNET_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
endef

define CADR_CHAOSNET_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(CADR_CHAOSNET_PKGDIR)/S87cadr-chaosnet \
		$(TARGET_DIR)/etc/init.d/S87cadr-chaosnet
endef

$(eval $(generic-package))
