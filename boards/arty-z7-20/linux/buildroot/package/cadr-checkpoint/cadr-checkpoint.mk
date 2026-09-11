# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The checkpoint program, one program per package as the others are.
# Buildroot's `local` site method builds straight from the src/ directory
# beside this file. `make buildroot-rebuild` at the repository root is what
# makes Buildroot notice a change here.
#
# What is in it:
#
#   cadr-checkpoint  reads the machine's memories through the console's
#                      readout window and its main memory through /dev/mem,
#                      digests the disk packs at the same instant, and writes
#                      a muir checkpoint with a sidecar binding it to those
#                      packs. src/cadr-checkpoint.c's header says how,
#                      src/pack_bind.h says why the binding exists, and
#                      `docs/checkpoint.md` is the procedure.
#
# **AND NO INIT SCRIPT, FOR THE CONSOLE'S REASON.** This program halts the
# machine while it reads. Started at boot it would halt a machine nobody
# asked it to halt, and the file it wrote would be of a CADR two seconds
# into its boot PROM.
#
# **IT BORROWS TWO LIBRARIES AND COPIES NEITHER.**  The shared transport ---
# /dev/mem, the EMIO tally guard, the logging --- is cadr-common's; the
# console's readout window is cadr-readout's. Buildroot's `local` site method
# rsyncs only a package's OWN src/ into the build directory, so a relative
# include of a sibling's files builds on the host and fails here; the way
# around that is a static library in the staging tree, which is what
# package/cadr-common/cadr-common.mk's header argues for at length and what
# cadr-readout now does as well. A second copy of `readout.c` in this package
# would be a second description of the console's window, and the window's own
# header already says what it costs to describe one thing twice.
#
# `STAGING_DIR/usr/include/cadr` is passed as `READOUT_INC` rather than being
# reached with an angle include, so that the same quoted `#include
# "readout.h"` serves the host build, where the directory is the sibling's
# own src/. `$(TARGET_CONFIGURE_OPTS)` already carries --sysroot, so the
# library needs no -L and cadr-common's headers need no -I at all.
#
# And `make -C src check` on the build host, which needs nothing but a C
# compiler: the program's core against a model of the window. The proof that
# the FORMAT is right is not there and cannot be --- it is `make
# build/checkpoint.pass` at the repository root, where muir opens the file
# this writes and writes its own, and the two are compared byte for byte.

CADR_CHECKPOINT_VERSION = 0
CADR_CHECKPOINT_SITE = $(BR2_EXTERNAL_CADR_PATH)/package/cadr-checkpoint/src
CADR_CHECKPOINT_SITE_METHOD = local
CADR_CHECKPOINT_LICENSE = AGPL-3.0-or-later
CADR_CHECKPOINT_DEPENDENCIES = cadr-common cadr-readout

define CADR_CHECKPOINT_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D) \
	    READOUT_INC=-I$(STAGING_DIR)/usr/include/cadr
endef

define CADR_CHECKPOINT_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
endef

$(eval $(generic-package))
