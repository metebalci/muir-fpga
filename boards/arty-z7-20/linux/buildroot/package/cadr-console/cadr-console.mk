# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The console, one program per package as the disk pack's Config.in said in
# September the second program would be.  Buildroot's `local` site method
# builds straight from the src/ directory beside this file --- no tarball, no
# version, no hash --- and `make buildroot-rebuild` at the repository root is
# what makes Buildroot notice a change here.
#
# What is in it:
#
#   cadr-console   halts the CADR, reads its sixteen diagnostic registers
#                    and starts it again, over M_AXI_GP1; from the command
#                    line or at a `>` prompt.  src/cadr-console.c's header
#                    says how, and src/console_face.h is the register window
#
# **AND NO INIT SCRIPT, DELIBERATELY.**  The disk pack program is a daemon
# because the disk controller waits on it; the console is a person at a
# prompt.  Started at boot it would hold a second master on the diagnostic
# bus for as long as the board was up, taking the bus from the processor's
# own Unibus cycles, and nobody would be reading what it said.
#
# The shared transport --- /dev/mem, the EMIO tally guard, the logging --- is
# cadr-common's, a static library in the staging tree.  Not a relative include
# of the sibling package's src/: `local` rsyncs only THIS package's src/ into
# the build directory, so those files are not there when this builds and such
# an include would work on the build host and fail under Buildroot.
# package/cadr-common/cadr-common.mk's header has the argument in full.
#
# And `make -C src check` on the build host, which needs nothing but a C
# compiler: the program's core against a model of the slave, with a modeled
# machine behind the diagnostic bus.

CADR_CONSOLE_VERSION = 0
CADR_CONSOLE_SITE = $(BR2_EXTERNAL_CADR_PATH)/package/cadr-console/src
CADR_CONSOLE_SITE_METHOD = local
CADR_CONSOLE_LICENSE = AGPL-3.0-or-later
CADR_CONSOLE_DEPENDENCIES = cadr-common

# **WHICH BUILD THE PROGRAM IS, PASSED IN BECAUSE THE BUILD CANNOT ASK.**
# `local` rsyncs `src/` into `output/build` and compiles there, so a `git`
# inside the package's own Makefile answers nothing under Buildroot --- the
# same hole `muir.mk` fills by handing cargo the pin.  These two are read HERE,
# where `$(BR2_EXTERNAL_CADR_PATH)` is a path inside the repository, and
# handed to the compile as `-D`s.  `:=` and not `=`, because Buildroot expands
# a package's variables many times over and each expansion would run the two
# git commands again.
#
# Empty when this is not a checkout, and the program then prints its version
# with no commit, as muir does with no `MUIR_GIT`.  `--dirty` rides on the
# commit for muir's reason: it is a fact about what was compiled against that
# commit rather than a field of its own.
CADR_CONSOLE_GIT := $(shell git -C $(BR2_EXTERNAL_CADR_PATH) rev-parse --short=7 HEAD 2>/dev/null)
CADR_CONSOLE_GIT_DIRTY := $(shell git -C $(BR2_EXTERNAL_CADR_PATH) status --porcelain 2>/dev/null | head -c 1)
ifneq ($(CADR_CONSOLE_GIT),)
CADR_CONSOLE_BUILD_GIT := $(CADR_CONSOLE_GIT)$(if $(CADR_CONSOLE_GIT_DIRTY),-dirty,)
endif

define CADR_CONSOLE_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D) \
		BUILD_GIT=$(CADR_CONSOLE_BUILD_GIT) PKG_VERSION=$(CADR_CONSOLE_VERSION)
endef

define CADR_CONSOLE_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
endef

$(eval $(generic-package))
