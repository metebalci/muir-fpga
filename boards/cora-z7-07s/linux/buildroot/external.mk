# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The Cora Z7-07S's BR2_EXTERNAL tree: no packages, and the two hooks that put
# this board's files where Buildroot's own options cannot.
#
# NO `include $(wildcard .../package/*/*.mk)` HERE.  The packages are the Arty
# Z7-20's tree's and that tree includes them; this build is given both trees
# and including them twice would define every package rule twice.  `Config.in`
# beside this file says why there is one copy of them.
#
# THE RESERVED-MEMORY NODE IS THE ARTY Z7-20's FILE, and that is deliberate:
# `boards/arty-z7-20/linux/cadr-reserved.dtsi` is the CADR's own 128 MB at
# 0x18000000, which `rtl/plumbing/cadr_ddr_map.sv` decides and which is a
# property of the MACHINE and not of the board.  Both boards carry 512 MB of
# DDR3 and reserve the same region of it, so a copy here would be a second
# description of one fact.  The kernel gets it by the hook below, copied next
# to the dts before the build, because BR2_LINUX_KERNEL_CUSTOM_DTS_DIR rsyncs
# a directory tree and a relative symlink breaks on arrival; U-Boot gets it by
# being listed in BR2_TARGET_UBOOT_CUSTOM_DTS_PATH.
#
# THE DEFAULT ENVIRONMENT IS A TEXT FILE U-Boot expects at
# board/xilinx/zynq/<CONFIG_ENV_SOURCE_FILE>.env (env/Kconfig, and the
# Makefile's ENV_DIR); nothing in Buildroot places a file there, so the second
# hook does.  Hooks appended here take effect because Buildroot expands
# $(PKG)_PRE_BUILD_HOOKS inside the recipe (package/pkg-generic.mk), after
# this file has been included.
#
# **AND THE TWO HOOKS HAVE NAMES OF THEIR OWN**, `CADR_CORA_*` rather than
# `CADR_*`: both trees' external.mk files are included into one make, and two
# `define` blocks with one name would leave whichever was read last.

CADR_CORA_BOARD_DIR = $(BR2_EXTERNAL_CADR_CORA_PATH)/board/cora-z7-07s
CADR_CORA_RESERVED_DTSI = $(BR2_EXTERNAL_CADR_PATH)/../cadr-reserved.dtsi

define CADR_CORA_LINUX_COPY_RESERVED_DTSI
	mkdir -p $(LINUX_ARCH_PATH)/boot/dts/xilinx
	cp -f $(CADR_CORA_RESERVED_DTSI) $(LINUX_ARCH_PATH)/boot/dts/xilinx/
endef
LINUX_PRE_BUILD_HOOKS += CADR_CORA_LINUX_COPY_RESERVED_DTSI

define CADR_CORA_UBOOT_COPY_ENV
	cp -f $(CADR_CORA_BOARD_DIR)/uboot/cadr_cora.env $(@D)/board/xilinx/zynq/
endef
UBOOT_PRE_BUILD_HOOKS += CADR_CORA_UBOOT_COPY_ENV

# **THE FILE IS `cadr_cora.env` AND NOT `cadr.env`, AND THAT IS NOT A NAMING
# PREFERENCE.**  Both trees' `external.mk` files are included into one make
# and both boards' hooks therefore run on every build.  The Arty Z7-20's copies
# its own `cadr.env` to `board/xilinx/zynq/cadr.env`; a Cora hook writing the
# same destination would put the two boards' environments in a race decided by
# which hook was appended last, and the loser's board would boot the winner's
# environment with no error anywhere.  Different names cannot race, and
# `uboot.fragment`'s `CONFIG_ENV_SOURCE_FILE` is what chooses between them.
