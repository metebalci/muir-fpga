# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The readout program, one program per package as the others are. Buildroot's
# `local` site method builds straight from the src/ directory beside this
# file. `make buildroot-rebuild` at the repository root is what makes
# Buildroot notice a change here.
#
# What is in it:
#
#   cadr-readout  prints the machine's own memories and its register table,
#                   read through the console's window on `M_AXI_GP1`.
#                   src/cadr-readout.c's header says how, and src/readout.h
#                   is the window.
#
# **AND NO INIT SCRIPT, FOR THE CONSOLE'S REASON.** This program halts the
# machine while it reads. Started at boot it would halt a machine nobody asked
# it to halt, and print a CADR two seconds into its boot PROM.
#
# **IT IS NOT THE DEBUGGER AND IS NOT MEANT TO BECOME ONE.** The debugger is
# CC over the debug cable, which reads the scratchpads by forcing a
# microinstruction into the instruction register --- the machine's own answer.
# This is the crude thing beside it.
#
# The shared transport --- /dev/mem, the EMIO tally guard, the logging --- is
# cadr-common's, a static library in the staging tree. Not a relative include
# of the sibling package's src/: `local` rsyncs only THIS package's src/ into
# the build directory, so those files are not there when this builds.
# package/cadr-common/cadr-common.mk's header has the argument in full.
#
# And `make -C src check` on the build host, which needs nothing but a C
# compiler: the program's core against a model of the window.

CADR_READOUT_VERSION = 0
CADR_READOUT_SITE = $(BR2_EXTERNAL_CADR_PATH)/package/cadr-readout/src
CADR_READOUT_SITE_METHOD = local
CADR_READOUT_LICENSE = AGPL-3.0-or-later
CADR_READOUT_DEPENDENCIES = cadr-common
# **THE WINDOW IS A LIBRARY AS WELL AS A PROGRAM.**  `cadr-checkpoint` drives
# the same readout and must not carry a copy of `readout.c`; Buildroot's
# `local` site method rsyncs only a package's own src/, so the way one package
# uses another's code here is a static library in the staging tree, which is
# what cadr-common already is. Nothing of this goes on the target --- the
# library is for linking and the program is the only thing installed.
CADR_READOUT_INSTALL_STAGING = YES

define CADR_READOUT_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)
endef

define CADR_READOUT_INSTALL_STAGING_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D) DESTDIR=$(STAGING_DIR) install-staging
endef

define CADR_READOUT_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
endef

$(eval $(generic-package))
