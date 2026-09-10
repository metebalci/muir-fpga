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
#   cadr-disk-pack      serves the CADR's disks from the drive bay on the
#                         card's second partition, on demand: the controller
#                         posts the block it lacks and this fetches it into
#                         the store, and takes written blocks back; and it
#                         watches the bay while the machine runs, so a pack
#                         copied in is a drive spinning up and one renamed
#                         out is a drive taken away.  src/cadr-disk-pack.c's
#                         header says how
#   S80cadr-disk-pack   mounts the card's boot partition read-only at
#                         /mnt/card and its pack partition read-write at
#                         /mnt/packs, and starts the program at boot, its log
#                         on the console
#
# And `make -C src check` on the build host, which needs nothing but a C
# compiler and build/disk.golden: the core against a model of the register
# face with a scripted controller behind it that asks for the reference
# trace's blocks and more, and the drive bay against a real directory of real
# files, because a rename and a delete are what has to be exercised.  `make
# -C src mutants` is what says that check can fail.

CADR_DISK_PACK_VERSION = 0
CADR_DISK_PACK_SITE = $(BR2_EXTERNAL_CADR_PATH)/package/cadr-disk-pack/src
CADR_DISK_PACK_SITE_METHOD = local
CADR_DISK_PACK_LICENSE = AGPL-3.0-or-later
# /dev/mem, the EMIO tally guard and the logging: a static library and its
# headers in the staging tree, because `local` rsyncs only this package's own
# src/ and a sibling's files are not there when this builds.
# package/cadr-common/cadr-common.mk's header has the argument.
CADR_DISK_PACK_DEPENDENCIES = cadr-common

define CADR_DISK_PACK_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)
endef

define CADR_DISK_PACK_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
endef

define CADR_DISK_PACK_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(CADR_DISK_PACK_PKGDIR)/S80cadr-disk-pack \
		$(TARGET_DIR)/etc/init.d/S80cadr-disk-pack
endef

$(eval $(generic-package))
