# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The screen, one program per package as cadr-disk-pack's Config.in said in
# September each of them would be --- "the console, the RFB server, the
# Chaosnet bridge and USB input each get their own beside this one".  This is
# the RFB server.  Buildroot's `local` site method builds straight from the
# src/ directory beside this file --- no tarball, no version, no hash --- and
# `make buildroot-rebuild` at the repository root is what makes Buildroot
# notice a change here.
#
# What is in it:
#
#   cadr-terminal       maps the display's region of DDR and serves it over
#                       RFB, RFC 6143, to a VNC viewer; read-only.
#                       src/cadr-terminal.c's header says how, and
#                       src/screen_geom.h is the geometry with its sources
#   S85cadr-terminal    starts it at boot, its log on the console
#
# **AND AN INIT SCRIPT, WHERE cadr-console HAS NONE.**  The console is a
# person at a prompt and started at boot would hold a second master on the
# diagnostic bus all day.  This one is a daemon like the disk pack program,
# and for the same kind of reason: what it holds while nobody is watching is
# a listening socket and nothing else --- it reads no DDR until a viewer
# connects --- so it costs a process and 92 KB, and it is there when somebody
# wants to look at the machine.  S85, after the disk pack program's S80, so
# that the first line of the log is about the drive.
#
# The shared transport --- /dev/mem, the EMIO tally guard, the logging --- is
# cadr-common's, a static library in the staging tree.  Not a relative include
# of the sibling package's src/: `local` rsyncs only THIS package's src/ into
# the build directory.  package/cadr-common/cadr-common.mk's header has the
# argument in full.
#
# And `make -C src check` on the build host, which needs nothing but a C
# compiler and python3: the server driven from screens made here, with a
# viewer written for the purpose on a loopback socket, and then every record
# in src/screen_mutations.txt, each of which the check must fail on.

CADR_TERMINAL_VERSION = 0
CADR_TERMINAL_SITE = $(BR2_EXTERNAL_CADR_PATH)/package/cadr-terminal/src
CADR_TERMINAL_SITE_METHOD = local
CADR_TERMINAL_LICENSE = AGPL-3.0-or-later
CADR_TERMINAL_DEPENDENCIES = cadr-common

define CADR_TERMINAL_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)
endef

define CADR_TERMINAL_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
endef

define CADR_TERMINAL_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(CADR_TERMINAL_PKGDIR)/S85cadr-terminal \
		$(TARGET_DIR)/etc/init.d/S85cadr-terminal
endef

$(eval $(generic-package))
